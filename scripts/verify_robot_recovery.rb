require "tmpdir"
require "timeout"

# Run only with the web server/normal worker stopped and reception paused.
# Uses fixed classifications; never calls Cloudflare. Actual timeout/kill cases
# move the simulator and return it through the administrator recovery path.
abort "先に管理コマンドpauseで受付を停止してください。" unless RobotState.singleton.maintenance?
abort "実APIワーカーを停止してください。" if SolidQueue::Process.where(kind: "Worker").exists?
abort "実動作モードで起動してください。" if ReceptionMode.preview?
after_restart = !!ARGV.delete("--after-simulator-restart")
cases = ARGV.reject { |value| value == "--" }
cases = %w[python_path ros_unavailable goal_rejected goal_aborted timeout python_killed] if cases.empty?
allowed = %w[python_path ros_unavailable goal_rejected goal_aborted timeout python_killed]
abort "未知の検証ケースです。" unless (cases - allowed).empty?
directory = Rails.root.join("docs/step14_failures")
directory.mkpath
summary = []
client = Object.new
client.define_singleton_method(:classify) do |input|
  raise ClefClient::Error.new("verification_only", "Verification input only") unless input.start_with?("STEP14 ")
  ClefClient::Classification.new(intent: "greeting", confidence: 0.9, probabilities: { "greeting" => 0.9 },
                               model: "verification-fixed", input_tokens: 0)
end
Rails.configuration.x.clef_client_factory = -> { client }
original_python = ENV["ROBOT_PYTHON"]
begin
  cases.each do |name|
    worker = fixture_pid = nil
    log = File.open(directory.join("#{name}.stderr"), "w")
    temporary = Dir.mktmpdir("recovery-ros-fixture")
    RobotRecovery.new.recover(resume: true, after_restart: after_restart)
    domain = %w[ros_unavailable goal_rejected goal_aborted].include?(name)
    fixture = Rails.root.join("test/support/ros_failure_fixture.py").to_s
    if %w[goal_rejected goal_aborted].include?(name)
      fixture_pid = Process.spawn({ "ROS_DOMAIN_ID" => "197", "ROS_LOCALHOST_ONLY" => "1" },
        RobotExecutor::PYTHON, "-u", fixture, "server", name == "goal_rejected" ? "reject" : "abort",
        pgroup: true, out: log, err: log)
      Timeout.timeout(10) { sleep 0.05 until File.read(log.path).include?("FIXTURE_READY") }
    end
    factory = ->(environment, python, flag, script, **settings) do
      environment = environment.merge("ROS_DOMAIN_ID" => "197", "ROS_LOCALHOST_ONLY" => "1") if domain
      Open3.popen3(environment, python, flag, fixture, "gesture", domain ? "normal" : "slow",
                  domain ? temporary : "-", **settings)
    end
    Rails.configuration.x.robot_executor_factory = -> {
      executor = RobotExecutor.new(process_factory: factory, timeout: name == "timeout" ? 4.5 : nil)
      if name == "python_killed"
        wrapper = Object.new
        wrapper.define_singleton_method(:call) do |action, **settings, &callback|
          pid = nil
          executor.call(action, **settings) do |event|
            accepted = callback.call(event)
            pid = event["pid"] if event["event"] == "process_started"
            Process.kill("KILL", pid) if event["event"] == "command_sent" && event["stage"] == "bow"
            accepted
          end
        end
        wrapper
      else
        executor
      end
    }
    ENV["ROBOT_PYTHON"] = name == "python_path" ? "/tmp/unconfigured-python" : RobotExecutor::PYTHON
    worker = SolidQueue::Worker.new(queues: [ "robot" ], threads: 1, polling_interval: 0.05, mode: :async)
    worker.start
    Timeout.timeout(5) { sleep 0.02 until RobotState.singleton.worker_online? }
    run = RobotSubmission.call(browser_id: SecureRandom.uuid, attributes: { input_text: "STEP14 #{name}" })
    Timeout.timeout(50) { sleep 0.05 while RobotRun.uncached { RobotRun.find(run.id).status.in?(RobotRun::ACTIVE_STATUSES) } }
    run.reload
    raise "Expected robot_failed for #{name}: #{run.status}" unless run.status == "robot_failed"
    expected = { "python_path" => "python_configuration_error", "ros_unavailable" => "robot_server_unavailable",
                 "goal_rejected" => "robot_goal_rejected", "goal_aborted" => "robot_action_failed",
                 "timeout" => "process_timeout", "python_killed" => "process_failed" }.fetch(name)
    raise "Unexpected error for #{name}: #{run.error_code}" unless run.error_code == expected
    raise "Reservation unexpectedly released" unless RobotState.singleton.current_run_id == run.id
    before = run.attributes.except("browser_id")
    RobotState.pause!
    worker.stop
    worker = nil
    ENV["ROBOT_PYTHON"] = RobotExecutor::PYTHON
    proof = RobotRecovery.new.recover(run_id: run.id, home: true, after_restart: after_restart)
    raise "Old job not revoked" unless run.reload.status == "recovered" && run.active_job_id.nil?
    summary << { name: name, failed_run: before, recovery: proof }
    File.write(directory.join("summary.json"), JSON.pretty_generate(summary) + "\n")
    puts "Verified #{name}: #{before['error_code']}, recovered run #{run.id}"
    $stdout.flush
  ensure
    RobotState.pause!
    worker&.stop
    if fixture_pid
      Process.kill("TERM", -fixture_pid) rescue nil
      Process.wait(fixture_pid) rescue nil
    end
    FileUtils.remove_entry(temporary) if temporary && File.exist?(temporary)
    log&.close
  end
ensure
  ENV["ROBOT_PYTHON"] = original_python
  Rails.configuration.x.clef_client_factory = nil
  Rails.configuration.x.robot_executor_factory = nil
end
puts "検証終了。受付は停止したままです。resume後に通常のワーカーを起動してください。"
