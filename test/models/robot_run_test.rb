require "test_helper"

class RobotRunTest < ActiveSupport::TestCase
  test "validates Unicode whitespace and a 200 character boundary" do
    [ "", " \n\t", "　" ].each do |input|
      run = RobotRun.new(browser_id: SecureRandom.uuid, input_text: input, preview_scenario: "greeting")
      refute run.valid?
      assert_includes run.errors[:input_text], "メッセージを入力してください。"
    end
    [ "あ", "😀" ].each do |character|
      run = RobotRun.new(browser_id: SecureRandom.uuid, input_text: character * 200, preview_scenario: "greeting")
      assert run.valid?
      run.input_text += character
      refute run.valid?
      assert_includes run.errors[:input_text], "メッセージは200文字以内で入力してください。"
    end
  end

  test "invalid scenarios cannot create a response or select a script" do
    run = RobotRun.new(browser_id: SecureRandom.uuid, input_text: "こんにちは", preview_scenario: "../../command")
    refute run.save
    assert run.errors[:preview_scenario].any?
    assert_nil run.action
  end

  test "form line endings are normalized before counting characters" do
    run = RobotRun.new(browser_id: SecureRandom.uuid, input_text: "あ" * 198 + "\r\nい", preview_scenario: "greeting")
    assert run.valid?
    assert_equal "あ" * 198 + "\nい", run.input_text
    assert_equal 200, run.input_text.length
  end
end
