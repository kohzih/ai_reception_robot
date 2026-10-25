class RobotRun < ApplicationRecord
  MAX_INPUT_CHARACTERS = ClefClient::MAX_INPUT_CHARACTERS
  HISTORY_LIMIT = 50
  before_validation :normalize_line_endings
  ACTIVE_STATUSES = %w[queued classifying dispatching moving].freeze
  STATUSES = (ACTIVE_STATUSES + %w[previewed preview_error completed classification_failed enqueue_failed robot_failed recovery_required]).freeze
  STATUS_LABELS = {
    "queued" => "確認待ち（仮処理）", "classifying" => "ご用件を確認中（仮処理）",
    "dispatching" => "仮応答を準備中", "previewed" => "仮応答を表示しました", "preview_error" => "失敗表示の例",
    "classification_failed" => "判断処理の失敗（表示例）", "enqueue_failed" => "受付できませんでした",
    "robot_failed" => "動作失敗の表示例・確認が必要です", "recovery_required" => "再開前の確認が必要です",
    "moving" => "指令送信済み", "completed" => "動作完了を確認しました"
  }.freeze

  validates :browser_id, presence: true
  validates :input_text, presence: { message: "メッセージを入力してください。" },
            length: { maximum: MAX_INPUT_CHARACTERS, message: "メッセージは200文字以内で入力してください。" }
  validates :preview_scenario, inclusion: { in: PreviewResponse::SCENARIOS.keys,
                                          message: "確認する仮応答を選んでください。" }, if: :preview?
  validates :status, inclusion: { in: STATUSES }
  validates :response_text, presence: true, unless: -> { ACTIVE_STATUSES.include?(status) }
  scope :for_browser, ->(browser_id) { where(browser_id: browser_id) }

  def status_label
    STATUS_LABELS.fetch(status)
  end

  private

  def normalize_line_endings
    self.input_text = input_text&.gsub(/\r\n?/, "\n")
  end
end
