module ClefTestData
  def self.response(intent: "hall", confidence: 0.8546)
    {
      "result" => {
        "model" => "clef",
        "answers" => { "intent" => {
          "type" => "choice", "choice" => intent, "confidence" => confidence,
          "probabilities" => ClefClient::INTENTS.to_h { |choice| [ choice, choice == intent ? 0.94 : 0.02 ] }
        } },
        "usage" => { "input_tokens" => 232, "output_tokens" => 0 }
      },
      "success" => true, "errors" => [], "messages" => []
    }
  end

  def self.classification(intent: "hall", confidence: 0.8546)
    response = self.response(intent: intent, confidence: confidence)
    ClefClient::Classification.new(intent: intent, confidence: confidence,
                                  probabilities: response.dig("result", "answers", "intent", "probabilities"),
                                  model: "clef", input_tokens: 232)
  end
end
