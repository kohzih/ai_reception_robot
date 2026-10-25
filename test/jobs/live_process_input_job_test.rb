require "test_helper"
require_relative "../support/robot_queue_test_support"
require_relative "../support/robot_process_test_support"

class LiveProcessInputJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include RobotQueueTestSupport
  include RobotProcessTestSupport
  setup do
    prepare_test_worker
    @previous_mode = Rails.configuration.x.reception_mode
    @previous_python = ENV["ROBOT_PYTHON"]
    Rails.configuration.x.reception_mode = "live"
    ENV["ROBOT_PYTHON"] = RobotExecutor::PYTHON
    Rails.configuration.x.robot_executor_factory = -> { fixture_executor }
  end
  teardown do
    Rails.configuration.x.reception_mode = @previous_mode
    Rails.configuration.x.clef_client_factory = nil
    Rails.configuration.x.robot_executor_factory = nil
    ENV["ROBOT_PYTHON"] = @previous_python
    restore_test_worker
  end

  def classify_as(intent, confidence = 0.9)
    classification = ClefClient::Classification.new(intent: intent, confidence: confidence,
      probabilities: { intent => 0.9 }, model: "clef", input_tokens: 100)
    client = Object.new
    client.define_singleton_method(:classify) { |_input| classification }
    Rails.configuration.x.clef_client_factory = -> { client }
  end

  test "all four classifications connect through selection events and verified process exit" do
    { "greeting" => "bow", "reception" => "reception", "hall" => "hall", "unknown" => "hold" }.each do |intent, action|
      classify_as(intent)
      run = submit_test_run
      refute run.preview?
      assert_nil run.preview_scenario
      perform_enqueued_jobs
      run.reload
      assert_equal "completed", run.status
      assert_equal action, run.action
      assert_equal ActionSelector::ACTIONS.fetch(intent).last, run.response_text
      assert_equal "clef", run.classification_model
      assert_equal 100, run.input_tokens
      assert run.command_sent_at
      assert run.motion_completed_at
      assert_operator run.finished_at, :>=, run.motion_completed_at
      assert_equal 0, run.robot_exit_code
      assert_equal "idle", RobotState.singleton.status
    end
  end

  test "a fixed low confidence hall classification dispatches hold and its matching message" do
    classify_as("hall", 0.4)
    run = submit_test_run
    perform_enqueued_jobs
    run.reload
    assert_equal "hall", run.intent
    assert_equal "hold", run.action
    assert_equal "low_confidence", run.selection_reason
    assert_equal ActionSelector::ACTIONS.fetch("unknown").last, run.response_text
    assert_equal "hold", run.robot_events.first["motion"]
    assert_equal "completed", run.status
  end

  test "API errors do not construct an executor and allow another input" do
    Rails.configuration.x.robot_executor_factory = -> { flunk "API error must never launch Python" }
    %w[connection_error authentication_error rate_limited server_error timeout invalid_response api_error].each do |code|
      Rails.configuration.x.clef_client_factory = -> { raise ClefClient::Error.new(code, "hidden") }
      run = submit_test_run
      perform_enqueued_jobs
      assert_equal "classification_failed", run.reload.status
      assert_equal code, run.error_code
      assert_nil run.command_sent_at
      assert_nil run.action
      assert_equal [], run.robot_events
      assert_equal "idle", RobotState.singleton.status
    end
  end

  test "the default client handles missing credentials without starting Python" do
    keys = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN]
    previous = keys.to_h { |key| [ key, ENV.delete(key) ] }
    Rails.configuration.x.clef_client_factory = nil
    run = submit_test_run
    perform_enqueued_jobs
    assert_equal "classification_failed", run.reload.status
    assert_equal "configuration_error", run.error_code
    assert_equal [], run.robot_events
    assert_equal "idle", RobotState.singleton.status
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  test "the default executor validates the configured interpreter before spawning" do
    classify_as("greeting")
    Rails.configuration.x.robot_executor_factory = nil
    ENV["ROBOT_PYTHON"] = "/tmp/invalid-python"
    run = submit_test_run
    perform_enqueued_jobs
    assert_equal "robot_failed", run.reload.status
    assert_equal "python_configuration_error", run.error_code
    assert_nil run.command_sent_at
    assert_equal "recovery_required", RobotState.singleton.status
  end

  test "a completion event followed by a nonzero exit keeps the reservation" do
    classify_as("greeting")
    Rails.configuration.x.robot_executor_factory = -> { fixture_executor("nonzero") }
    run = submit_test_run
    perform_enqueued_jobs
    assert_equal "robot_failed", run.reload.status
    assert_equal 7, run.robot_exit_code
    assert run.motion_completed_at
    assert_equal "process_failed", run.error_code
    assert_equal "recovery_required", RobotState.singleton.status
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "completion stays moving until the process also exits successfully" do
    classify_as("greeting")
    saw_terminal_event = false
    executor = fixture_executor("slow_exit")
    wrapper = Object.new
    wrapper.define_singleton_method(:call) do |action, **options, &callback|
      executor.call(action, **options) do |event|
        accepted = callback.call(event)
        if event["event"] == "completed"
          run = RobotRun.order(:id).last
          raise "Premature completion" unless run.status == "moving" && run.finished_at.nil?
          saw_terminal_event = true
        end
        accepted
      end
    end
    Rails.configuration.x.robot_executor_factory = -> { wrapper }
    run = submit_test_run
    perform_enqueued_jobs
    assert saw_terminal_event
    assert_equal "completed", run.reload.status
  end
end
