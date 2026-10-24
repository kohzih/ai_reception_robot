class RobotRun < ApplicationRecord
  MAX_INPUT_CHARACTERS = ClefClient::MAX_INPUT_CHARACTERS
  HISTORY_LIMIT = 50
  before_validation :normalize_line_endings
  before_validation :apply_preview_response, on: :create, if: :preview?

  validates :browser_id, presence: true
  validates :input_text, presence: { message: "メッセージを入力してください。" },
            length: { maximum: MAX_INPUT_CHARACTERS, message: "メッセージは200文字以内で入力してください。" }
  validates :preview_scenario, inclusion: { in: PreviewResponse::SCENARIOS.keys,
                                          message: "確認する仮応答を選んでください。" }, if: :preview?
  validates :status, inclusion: { in: %w[previewed preview_error], message: "仮応答を表示できませんでした。" }
  validates :response_text, presence: { message: "仮応答を表示できませんでした。" }
  scope :for_browser, ->(browser_id) { where(browser_id: browser_id) }

  private

  def normalize_line_endings
    self.input_text = input_text&.gsub(/\r\n?/, "\n")
  end

  def apply_preview_response
    attributes = PreviewResponse.attributes_for(preview_scenario)
    assign_attributes(attributes) if attributes
  end
end
