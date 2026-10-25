require "test_helper"
require_relative "../support/robot_queue_test_support"

class ChatLiveTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RobotQueueTestSupport
  setup do
    prepare_test_worker
    @previous_mode = Rails.configuration.x.reception_mode
    Rails.configuration.x.reception_mode = "live"
  end
  teardown do
    Rails.configuration.x.reception_mode = @previous_mode
    restore_test_worker
  end

  test "the server chooses live mode and ignores client supplied preview and status" do
    get root_path
    assert_select ".mode-badge", text: "AI受付モード"
    assert_select "select[name='robot_run[preview_scenario]']", count: 0
    post chat_path, params: { robot_run: { input_text: "こんにちは。", preview: true,
      preview_scenario: "../../shell", status: "completed", action: "hall", response_text: "forged" } }, as: :json
    assert_response :accepted
    run = RobotRun.sole
    refute run.preview?
    assert_nil run.preview_scenario
    assert_nil run.action
    assert_equal "queued", run.status
    get robot_run_path(run), as: :json
    assert_equal "確認待ち", response.parsed_body["status_label"]
    assert_equal false, response.parsed_body["preview"]
  end
end
