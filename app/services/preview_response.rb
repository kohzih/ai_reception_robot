class PreviewResponse
  SCENARIOS = {
    "greeting" => { label: "挨拶", intent: "greeting", confidence: 0.9 },
    "reception" => { label: "受付への案内", intent: "reception", confidence: 0.9 },
    "hall" => { label: "講演会場への案内", intent: "hall", confidence: 0.9 },
    "unknown" => { label: "案内先が不明", intent: "unknown", confidence: 0.9 },
    "low_confidence" => { label: "信頼度が低い場合", intent: "hall", confidence: 0.4 },
    "classification_error" => { label: "判断処理の失敗", error: "classification_failed" },
    "robot_error" => { label: "動作処理の失敗", intent: "hall", confidence: 0.9, error: "robot_failed" }
  }.freeze

  def self.attributes_for(scenario)
    definition = SCENARIOS[scenario]
    return unless definition
    if definition[:intent]
      classification = ClefClient::Classification.new(intent: definition[:intent], confidence: definition[:confidence],
                                                     probabilities: {}, model: "preview", input_tokens: 0)
      selection = ActionSelector.call(classification)
    else
      selection = ActionSelector.failure
    end
    {
      status: definition[:error] ? "preview_error" : "previewed",
      intent: definition[:intent], confidence: definition[:confidence], action: selection.action,
      response_text: scenario == "robot_error" ? "動作の実行に失敗しました。" : selection.message,
      error_code: definition[:error]
    }
  end
end
