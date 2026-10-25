require "application_system_test_case"
require_relative "../support/robot_system_worker"
require_relative "../support/robot_process_test_support"

class ChatLiveSystemTest < ApplicationSystemTestCase
  self.use_transactional_tests = false
  include RobotSystemWorker
  include RobotProcessTestSupport
  setup do
    @previous_mode = Rails.configuration.x.reception_mode
    @previous_python = ENV["ROBOT_PYTHON"]
    Rails.configuration.x.reception_mode = "live"
    ENV["ROBOT_PYTHON"] = RobotExecutor::PYTHON
    client = Object.new
    client.define_singleton_method(:classify) do |input|
      raise ClefClient::Error.new("timeout", "Injected timeout") if input == "API失敗"
      intent = { "こんにちは。" => "greeting", "参加受付はどこですか？" => "reception",
                 "講演会場はどちらですか？" => "hall", "どこに行けばいいですか？" => "unknown" }.fetch(input)
      ClefClient::Classification.new(intent: intent, confidence: 0.9, probabilities: { intent => 0.9 }, model: "clef", input_tokens: 100)
    end
    Rails.configuration.x.clef_client_factory = -> { client }
    Rails.configuration.x.robot_executor_factory = -> { fixture_executor("slow_motion") }
    start_system_worker
  end
  teardown do
    stop_system_worker
    Rails.configuration.x.reception_mode = @previous_mode
    Rails.configuration.x.clef_client_factory = nil
    Rails.configuration.x.robot_executor_factory = nil
    ENV["ROBOT_PYTHON"] = @previous_python
  end

  test "the live screen connects four choices and distinguishes sent from completed" do
    visit root_path
    assert_text "AI受付モード"
    assert_no_select "確認する仮応答"
    [ "こんにちは", "受付を探す", "講演会場を探す", "案内先がわからない" ].each_with_index do |example, index|
      click_button example
      click_button "送信する"
      assert_selector '.conversation-entry:last-of-type[data-run-status="moving"]'
      assert_text "指令送信済み"
      assert_button "送信する", disabled: true
      assert_nil RobotRun.uncached { RobotRun.order(:id).last.finished_at }
      assert_selector '.conversation-entry:last-of-type[data-run-status="completed"]'
      assert_text "動作完了を確認しました"
      assert_text "入力できます"
      assert_equal index + 1, RobotRun.uncached { RobotRun.count }
    end
    refresh
    assert_selector ".conversation-entry", count: 4
    assert_no_selector ".conversation-entry .preview-label", text: "仮応答"
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.save_screenshot(Rails.root.join("tmp/screenshots/step13_live.png"))
  end

  test "an API failure leaves the arm uncommanded and permits input again" do
    visit root_path
    fill_in "メッセージ", with: "API失敗"
    click_button "送信する"
    assert_text "判断処理に失敗しました。もう一度お試しください。"
    assert_text "入力できます"
    run = RobotRun.sole
    assert_equal "classification_failed", run.status
    assert_nil run.command_sent_at
    assert_equal [], run.robot_events
    fill_in "メッセージ", with: "こんにちは。"
    assert_button "送信する", disabled: false
  end
end
