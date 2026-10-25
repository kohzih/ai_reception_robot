require "net/http"
require "timeout"

if ARGV.include?("--worker")
  kind = ARGV.last
  abort "検証ワーカーの種類が不正です。" unless %w[normal orphan].include?(kind)
  client = Object.new
  client.define_singleton_method(:classify) do |input|
    raise ClefClient::Error.new("verification_only", "Verification input only") unless input.start_with?("STEP14 ")
    ClefClient::Classification.new(intent: "greeting", confidence: 0.9, probabilities: {}, model: "verification-fixed", input_tokens: 0)
  end
  Rails.configuration.x.clef_client_factory = -> { client }
  factory = ->(environment, python, flag, script, **settings) {
    Open3.popen3(environment, python, flag, Rails.root.join("test/support/ros_failure_fixture.py").to_s,
      "gesture", kind, "-", **settings)
  }
  Rails.configuration.x.robot_executor_factory = -> { RobotExecutor.new(process_factory: factory) }
  worker = SolidQueue::Worker.new(queues: [ "robot" ], threads: 1, polling_interval: 0.05, mode: :async)
  stopping = false
  Signal.trap("TERM") { stopping = true }
  begin
    worker.start
    sleep 0.05 until stopping
  ensure
    worker.stop
  end
  exit
end

abort "未知の検証オプションです。" unless (ARGV - %w[-- --rails-only --after-simulator-restart]).empty?
abort "受付をpauseしてから実行してください。" unless RobotState.singleton.maintenance?
after_restart = ARGV.include?("--after-simulator-restart")
logs = Rails.root.join("docs/step14_restart")
logs.mkpath
def await(seconds = 20, &block)
  Timeout.timeout(seconds) { sleep 0.05 until yield }
end
def start_verification_worker(kind, logs)
  pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", __FILE__, "--", "--worker", kind,
    pgroup: true, out: logs.join("worker_#{kind}.log").to_s, err: :out)
  await { RobotState.singleton.worker_online? }
  pid
end
def stop(pid)
  Process.kill("TERM", pid)
  Timeout.timeout(12) { Process.wait(pid) }
rescue Errno::ESRCH, Errno::ECHILD
  nil
end
def request(method, path, cookie: nil, token: nil, body: nil)
  message = Net::HTTP.const_get(method.capitalize).new(path)
  message["Accept"] = path == "/" || path == "/chat/history" ? "text/html" : "application/json"
  message["Cookie"] = cookie if cookie
  message["X-CSRF-Token"] = token if token
  if body
    message["Content-Type"] = "application/json"
    message.body = JSON.generate(body)
  end
  Net::HTTP.start("127.0.0.1", 3000, nil, open_timeout: 1, read_timeout: 3) { |http| http.request(message) }
end
def start_rails(logs)
  pid = Process.spawn(RbConfig.ruby, Rails.root.join("bin/rails").to_s, "server", "-b", "0.0.0.0", "-p", "3000",
    pgroup: true, out: logs.join("rails.log").to_s, err: :out)
  File.write(logs.join("rails.pid"), pid.to_s)
  await do
    request("get", "/up").code == "200" rescue false
  end
  pid
end

report = ARGV.include?("--rails-only") && logs.join("summary.json").exist? ? JSON.parse(logs.join("summary.json").read) : {}
worker_pid = server_pid = nil
begin
  unless ARGV.include?("--rails-only")
  RobotRecovery.new.recover(resume: true, after_restart: after_restart)
  worker_pid = start_verification_worker("orphan", logs)
  run = RobotSubmission.call(browser_id: SecureRandom.uuid, attributes: { input_text: "STEP14 worker killed" })
  await { RobotRun.uncached { RobotRun.find(run.id).robot_events.any? { |event| event["event"] == "command_sent" && event["stage"] == "bow" } } }
  original_pid, original_epoch = run.reload.robot_process["pid"], run.worker_epoch
  Process.kill("KILL", worker_pid)
  Process.wait(worker_pid)
  worker_pid = nil
  await { !RobotState.singleton.worker_online? }
  RobotState.reconcile!
  raise "Worker loss did not retain reservation" unless run.reload.status == "recovery_required" && RobotState.singleton.current_run_id == run.id
  worker_pid = start_verification_worker("normal", logs)
  sleep 0.5
  raise "Old run was replayed" unless run.reload.robot_process["pid"] == original_pid && run.status == "recovery_required"
  raise "Worker epoch was not fenced" if RobotState.singleton.worker_epoch == original_epoch
  RobotState.pause!
  stop(worker_pid)
  worker_pid = nil
  termination = RobotRecovery.new.stop_process(run_id: run.id)
  proof = RobotRecovery.new.recover(run_id: run.id, home: true, after_restart: after_restart)
  report[:worker_killed] = { run_id: run.id, replayed: false, termination: termination, recovery: proof }
  File.write(logs.join("summary.json"), JSON.pretty_generate(report) + "\n")
  puts "Verified worker kill/restart: old run fenced, owned process stopped, physics recovered"
  $stdout.flush
  end

  RobotRecovery.new.recover(resume: true, after_restart: after_restart)
  worker_pid = start_verification_worker("normal", logs)
  server_pid = start_rails(logs)
  page = request("get", "/")
  cookie = page.get_fields("set-cookie").map { |value| value.split(";").first }.join("; ")
  token = Nokogiri::HTML(page.body).at_css('meta[name="csrf-token"]')["content"]
  response = request("post", "/chat", cookie: cookie, token: token, body: { robot_run: { input_text: "STEP14 Rails restart" } })
  raise "HTTP submission failed" unless response.code == "202"
  run = RobotRun.find(JSON.parse(response.body).fetch("run_id"))
  await { RobotRun.uncached { RobotRun.find(run.id).status == "moving" } }
  pid_before, epoch_before = run.reload.robot_process["pid"], run.worker_epoch
  stop(server_pid)
  server_pid = start_rails(logs)
  screen = JSON.parse(request("get", "/chat/state", cookie: cookie).body)
  raise "Browser ownership was lost" unless screen["own_active_run_id"] == run.id
  await { RobotRun.uncached { RobotRun.find(run.id).status == "completed" } }
  run.reload
  raise "Motion was restarted" unless run.robot_process["pid"] == pid_before && run.worker_epoch == epoch_before &&
    run.robot_events.count { |event| event["event"] == "process_started" } == 1
  raise "History was lost" unless request("get", "/chat/history", cookie: cookie).body.include?("STEP14 Rails restart")
  report[:rails_restart] = { run_id: run.id, status: run.status, same_browser: true, replayed: false, robot_exit_code: run.robot_exit_code }
  File.write(logs.join("summary.json"), JSON.pretty_generate(report) + "\n")
  puts "Verified Rails restart: same browser restored one ongoing motion and completion"
ensure
  RobotState.pause!
  stop(worker_pid) if worker_pid
  Process.detach(server_pid) if server_pid
end
puts "受付は停止中。検証用ワーカーは終了し、Railsは起動したままです。"
