require "test_helper"
require_relative "../support/clef_test_data"

class ActionSelectorTest < ActiveSupport::TestCase
  test "known classifications select only the four allowed scripts and matching messages" do
    { "greeting" => [ "bow", "お辞儀します。" ],
      "reception" => [ "reception", "受付の方向を示します。" ],
      "hall" => [ "hall", "講演会場の方向を示します。" ],
      "unknown" => [ "hold", "案内先を特定できませんでした。保留の合図をします。" ] }.each do |intent, (action, message)|
      selection = ActionSelector.call(ClefTestData.classification(intent: intent))
      assert_equal action, selection.action
      assert_equal "scripts/robot/#{action}.py", selection.script
      assert_equal message, selection.message
    end
  end

  test "confidence strictly below 0.5 uses hold with the hold message" do
    [ 0, 0.2130, 0.4999 ].each do |confidence|
      selection = ActionSelector.call(ClefTestData.classification(confidence: confidence))
      assert_equal "hold", selection.action
      assert_equal "scripts/robot/hold.py", selection.script
      assert_equal "low_confidence", selection.reason
      assert_equal ActionSelector::ACTIONS.fetch("unknown").last, selection.message
    end
  end

  test "confidence equal to 0.5 remains eligible for its classified action" do
    [ 0.5, 1.0 ].each do |confidence|
      selection = ActionSelector.call(ClefTestData.classification(confidence: confidence))
      assert_equal "hall", selection.action
      assert_equal "classified", selection.reason
    end
    assert_equal "hold", ActionSelector.call(ClefTestData.classification(intent: "unknown", confidence: 1.0)).action
  end

  test "invalid classification and nonfinite confidence never select a motion" do
    [ nil, {}, ClefTestData.classification(intent: "../../command"),
      *[ nil, true, "0.9", -0.1, 1.1, Float::NAN, Float::INFINITY ].map { |confidence|
        ClefTestData.classification(confidence: confidence)
      } ].each do |classification|
      selection = ActionSelector.call(classification)
      assert_nil selection.action
      assert_nil selection.script
      assert_equal "invalid_classification", selection.reason
    end
  end

  test "API failure means no selected action including hold" do
    selection = ActionSelector.failure
    assert_nil selection.action
    assert_nil selection.script
    assert_equal "判断処理に失敗しました。もう一度お試しください。", selection.message
  end
end
