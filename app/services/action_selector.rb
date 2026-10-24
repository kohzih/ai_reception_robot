class ActionSelector
  CONFIDENCE_THRESHOLD = 0.5
  Selection = Data.define(:action, :script, :message, :reason)
  ACTIONS = {
    "greeting" => [ "bow", "お辞儀します。" ],
    "reception" => [ "reception", "受付の方向を示します。" ],
    "hall" => [ "hall", "講演会場の方向を示します。" ],
    "unknown" => [ "hold", "案内先を特定できませんでした。保留の合図をします。" ]
  }.freeze

  def self.call(classification)
    unless classification.is_a?(ClefClient::Classification) &&
        ClefClient::INTENTS.include?(classification.intent) && ClefClient.valid_confidence?(classification.confidence)
      return failure(reason: "invalid_classification")
    end
    low_confidence = classification.confidence < CONFIDENCE_THRESHOLD
    intent = low_confidence ? "unknown" : classification.intent
    action, message = ACTIONS.fetch(intent)
    reason = low_confidence ? "low_confidence" : (intent == "unknown" ? "unknown" : "classified")
    Selection.new(action: action, script: "scripts/robot/#{action}.py", message: message, reason: reason)
  end

  def self.failure(reason: "api_error")
    Selection.new(action: nil, script: nil, message: "判断処理に失敗しました。もう一度お試しください。", reason: reason)
  end
end
