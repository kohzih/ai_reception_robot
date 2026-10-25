# Standalone subprocess fixture: no ROS, network or robot access.
require "json"
$stdout.sync = $stderr.sync = true
variant, motion = ARGV
abort "Credentials reached the motion process" if ENV["CLOUDFLARE_API_TOKEN"] || ENV["CLOUDFLARE_ACCOUNT_ID"]
emit = ->(event, **fields) { puts JSON.generate({ event: event, motion: motion, elapsed_sec: 0.1 }.merge(fields)) }
case variant
when "hang"
  Signal.trap("TERM", "IGNORE")
  loop { sleep 0.02 }
when "invalid_json" then puts "invalid"
when "truncated" then print '{"event":"started"}'
when "stdout_limit" then puts "x" * 70_000
when "stderr_limit" then $stderr.write("x" * 70_000)
when "silent" then exit 0
when "killed" then Process.kill("KILL", Process.pid)
else
  motion = "other" if variant == "wrong_motion"
  emit.call("started")
  if variant == "failed"
    emit.call("failed", code: "server_unavailable", requires_recovery: false, stop_confirmed: false)
    exit 1
  end
  if variant == "early_completion"
    emit.call("completed")
    exit 0
  end
  $stderr.write("diagnostic\n" * 5000)
  stages = case motion
  when "bow" then %w[front bow return]
  when "hold" then %w[front open_ready close_1 open_1 close_2 open_2]
  else %w[front turn bow upright return]
  end
  stages.each do |stage|
    controller = motion == "hold" && stage != "front" ? "gripper" : "arm"
    emit.call("command_sent", stage: stage, controller: controller, goal_id: "a" * 32)
    sleep 1.2 if variant == "slow_motion" && stage == "front"
    emit.call("stage_completed", stage: stage, action_status: 4, result_error_code: variant == "bad_result" ? 1 : 0)
  end
  emit.call("completed") unless variant == "missing_completion"
  sleep 0.3 if %w[slow_exit slow_motion].include?(variant)
  exit 7 if variant == "nonzero"
end
