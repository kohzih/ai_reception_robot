class RobotScreenState
  def self.call(browser_id)
    state = RobotState.reconcile!
    online = state.worker_online?
    own_run = state.current_run if state.current_run&.browser_id == browser_id
    message = if state.status == "recovery_required"
      "再開前の確認が必要です。受付を停止しています。"
    elsif state.status != "idle"
      own_run ? own_run.status_label : "ほかの受付対応中です。完了までお待ちください。"
    elsif !online
      "受付の準備ができていません。しばらくお待ちください。"
    else
      "入力できます"
    end
    latest = RobotRun.for_browser(browser_id).order(updated_at: :desc, id: :desc).pick(:id, :updated_at)
    {
      available: online && state.status == "idle", worker_online: online,
      message: message, recovery_required: state.status == "recovery_required",
      own_active_run_id: own_run&.id,
      history_version: latest ? "#{latest[0]}:#{latest[1].utc.iso8601(6)}" : ""
    }
  end
end
