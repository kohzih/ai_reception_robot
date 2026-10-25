require "test_helper"
require_relative "../support/robot_process_test_support"

class RobotExecutorTest < ActiveSupport::TestCase
  include RobotProcessTestSupport
  setup do
    @previous_environment = %w[ROBOT_PYTHON CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN].to_h { |key| [ key, ENV[key] ] }
    ENV["ROBOT_PYTHON"] = RobotExecutor::PYTHON
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "never-inherit-account"
    ENV["CLOUDFLARE_API_TOKEN"] = "never-inherit-token"
  end
  teardown { @previous_environment.each { |key, value| ENV[key] = value } }

  test "all four fixed commands consume both pipes and require every settled stage" do
    RobotExecutor::SCRIPTS.each_key do |action|
      command = nil
      factory = fixture_process_factory { |*arguments| command = arguments }
      events = []
      result = RobotExecutor.new(process_factory: factory).call(action) { |event| events << event }
      assert result.success
      assert_equal 0, result.exit_code
      assert_equal [ RobotExecutor::PYTHON, "-u", RobotExecutor::SCRIPTS.fetch(action) ], command[1..3]
      assert_nil command[0]["CLOUDFLARE_API_TOKEN"]
      assert_equal true, command[4][:pgroup]
      assert_equal RobotExecutor::STAGES.fetch(action), events.select { |e| e["event"] == "stage_completed" }.map { |e| e["stage"] }
      assert_equal "completed", events.last["event"]
    end
  end

  test "completion events alone and clean exits alone cannot report success" do
    {
      "early_completion" => "completion_unconfirmed", "missing_completion" => "completion_unconfirmed",
      "silent" => "completion_unconfirmed", "nonzero" => "process_failed", "killed" => "process_failed"
    }.each do |variant, expected|
      result = fixture_executor(variant).call("bow")
      refute result.success, variant
      assert_equal expected, result.error_code, variant
    end
  end

  test "invalid protocol and unsuccessful action results never succeed" do
    %w[invalid_json truncated wrong_motion bad_result].each do |variant|
      result = fixture_executor(variant).call("bow")
      refute result.success, variant
      assert_equal "invalid_event", result.error_code, variant
    end
  end

  test "both output streams have a hard size bound" do
    %w[stdout_limit stderr_limit].each do |variant|
      result = fixture_executor(variant).call("bow")
      refute result.success
      assert_equal "output_limit", result.error_code
    end
  end

  test "a failed event retains the Python error and exit code" do
    result = fixture_executor("failed").call("bow")
    refute result.success
    assert_equal "robot_server_unavailable", result.error_code
    assert_equal 1, result.exit_code
  end

  test "deadline escalation reaps a child which ignores termination" do
    pid = nil
    factory = fixture_process_factory("hang")
    wrapper = ->(*args, **options) { factory.call(*args, **options).tap { |child| pid = child.last.pid } }
    result = RobotExecutor.new(process_factory: wrapper, timeout: 0.3, termination_grace: 0.1).call("bow")
    refute result.success
    assert_equal "process_timeout", result.error_code
    assert_operator result.duration_ms, :<, 2000
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  test "an untrusted action or invalid Python path never reaches spawn" do
    calls = 0
    executor = RobotExecutor.new(process_factory: ->(*) { calls += 1 })
    assert_equal "invalid_action", executor.call("../../shell; echo unsafe").error_code
    ENV["ROBOT_PYTHON"] = "/tmp/untrusted-python"
    assert_equal "python_configuration_error", executor.call("bow").error_code
    assert_equal 0, calls
  end

  test "a rejected launch and lost ownership cannot leave a running child" do
    calls = 0
    executor = RobotExecutor.new(process_factory: ->(*) { calls += 1 })
    result = executor.call("bow", launch_guard: ->(&block) { false })
    assert_equal "reservation_lost", result.error_code
    assert_equal 0, calls
    result = fixture_executor("hang").call("bow", continuing: -> { false })
    assert_equal "reservation_lost", result.error_code
    refute result.success
  end

  test "callback failures terminate the child and cannot report completion" do
    result = fixture_executor("success").call("bow") { |_event| raise "Database unavailable" }
    refute result.success
    assert_equal "event_processing_failed", result.error_code
  end
end
