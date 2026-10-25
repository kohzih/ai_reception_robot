class RobotSubmission
  class Unavailable < StandardError
    attr_reader :http_status
    def initialize(message, http_status:)
      @http_status = http_status
      super(message)
    end
  end

  def self.call(browser_id:, attributes:)
    run = RobotRun.new(attributes.merge(browser_id: browser_id, preview: true))
    raise ActiveRecord::RecordInvalid, run unless run.valid?
    state = RobotState.reconcile!
    if state.status != "idle"
      raise Unavailable.new("ほかの受付処理中、または再開前の確認が必要です。", http_status: 409)
    end
    unless state.worker_online?
      raise Unavailable.new("受付の準備ができていません。しばらくしてからお試しください。", http_status: 503)
    end
    epoch = state.worker_epoch
    job = nil
    RobotState.transaction do
      claimed = RobotState.where(id: 1, status: "idle", worker_epoch: epoch, worker_accepting: true)
                          .update_all(status: "reserved", updated_at: Time.current)
      raise Unavailable.new("ほかの受付処理中です。完了までお待ちください。", http_status: 409) unless claimed == 1
      run.worker_epoch = epoch
      run.queued_at = Time.current
      run.save!
      job = ProcessInputJob.new(run.id, epoch)
      run.update!(active_job_id: job.job_id)
      RobotState.find(1).update!(current_run_id: run.id)
    end
    begin
      result = job.enqueue
      raise ActiveJob::EnqueueError, "Enqueue was not confirmed" unless result && job.successfully_enqueued?
      run.update!(enqueued_at: Time.current)
    rescue StandardError
      RobotState.fail_enqueue!(run.id, epoch)
      raise Unavailable.new("受付できませんでした。処理状態を確認してください。", http_status: 503), cause: nil
    end
    run.reload
  end
end
