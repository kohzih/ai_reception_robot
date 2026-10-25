class RobotState < ApplicationRecord
  HEARTBEAT_TIMEOUT = 10.seconds
  START_TIMEOUT = 15.seconds
  PROCESS_TIMEOUT = 120.seconds
  belongs_to :current_run, class_name: "RobotRun", optional: true
  validates :status, inclusion: { in: %w[idle reserved processing recovery_required] }

  def self.singleton
    uncached { find_by(id: 1) || create_or_find_by!(id: 1) }
  end

  # The first statement in this transaction is a write, including on SQLite.
  def self.locked
    singleton
    transaction do
      where(id: 1).update_all(updated_at: Time.current)
      yield find(1)
    end
  end

  def self.worker_live?(process_id)
    return false unless process_id
    process = SolidQueue::Process.uncached { SolidQueue::Process.find_by(id: process_id, kind: "Worker") }
    process.present? && process.last_heartbeat_at > HEARTBEAT_TIMEOUT.ago &&
      process.metadata["queues"] == "robot" && process.metadata["pool_size"] == 1
  rescue ActiveRecord::StatementInvalid
    false
  end

  def worker_online?
    worker_accepting && self.class.worker_live?(worker_process_id)
  end

  def self.register_worker!(process_id)
    return unless worker_live?(process_id)
    previous = singleton
    return if previous.maintenance?
    return if previous.worker_process_id != process_id && previous.worker_online?
    locked do |state|
      next unless !state.maintenance? && state.worker_process_id == previous.worker_process_id && state.worker_epoch == previous.worker_epoch
      require_recovery!(state, "worker_restarted") if state.current_run_id
      epoch = SecureRandom.uuid
      state.update!(worker_process_id: process_id, worker_epoch: epoch, worker_accepting: true)
      epoch
    end
  end

  def self.stop_accepting!(process_id)
    where(id: 1, worker_process_id: process_id).update_all(worker_accepting: false) if process_id
  end

  def self.unregister_worker!(process_id)
    return unless process_id
    locked do |state|
      next unless state.worker_process_id == process_id
      require_recovery!(state, "worker_stopped") if state.current_run_id
      state.update!(worker_process_id: nil, worker_epoch: nil, worker_accepting: false)
    end
  end

  def self.reconcile!
    state = singleton
    return state unless state.current_run_id && state.status != "recovery_required"
    online = state.worker_online?
    locked do |current|
      next current unless current.current_run_id == state.current_run_id && current.status != "recovery_required"
      run = current.current_run
      reason = if !online
        "worker_unavailable"
      elsif run.nil? || !RobotRun::ACTIVE_STATUSES.include?(run.status)
        "state_inconsistent"
      elsif run.status == "queued" && (!run.queued_at || run.queued_at < START_TIMEOUT.ago)
        run.enqueued_at ? "job_not_started" : "enqueue_unconfirmed"
      elsif run.started_at && run.started_at < PROCESS_TIMEOUT.ago
        "processing_timeout"
      end
      require_recovery!(current, reason) if reason
      current
    end
  end

  def self.claim!(run_id, job_id, epoch)
    return false unless worker_live?(Rails.configuration.x.robot_worker_process_id)
    locked do |state|
      next false unless owner?(state, run_id, epoch) && state.status == "reserved" && !state.maintenance?
      next false unless Rails.configuration.x.robot_worker_process_id == state.worker_process_id &&
                        Rails.configuration.x.robot_worker_epoch == epoch
      run = state.current_run
      next false unless run.status == "queued" && run.active_job_id == job_id
      if !run.queued_at || run.queued_at < START_TIMEOUT.ago || !state.worker_accepting?
        require_recovery!(state, "job_not_started")
        next false
      end
      run.update!(status: "classifying", started_at: Time.current)
      state.update!(status: "processing")
      true
    end
  end

  def self.transition!(run_id, epoch, from:, to:, attributes: {})
    locked do |state|
      next false unless owner?(state, run_id, epoch) && state.status == "processing" && state.worker_accepting?
      run = state.current_run
      next false unless run.status == from
      run.update!(attributes.merge(status: to))
      true
    end
  end

  def self.finish!(run_id, epoch, status:, attributes: {}, release:)
    locked do |state|
      next false unless owner?(state, run_id, epoch) && state.status == "processing"
      state.current_run.update!(attributes.merge(status: status, finished_at: Time.current))
      state.update!(status: release ? "idle" : "recovery_required", current_run_id: release ? nil : run_id)
      true
    end
  end

  # Keep the launch itself inside the reservation transaction, not the motion.
  def self.with_dispatch_permission(run_id, epoch)
    locked do |state|
      next false unless owner?(state, run_id, epoch) && state.status == "processing" &&
                        state.worker_accepting? && state.current_run.status == "dispatching"
      yield
    end
  end

  def self.execution_permitted?(run_id, epoch)
    state = singleton
    owner?(state, run_id, epoch) && state.status == "processing" && state.worker_accepting? && state.worker_online?
  end

  def self.record_event!(run_id, epoch, event)
    locked do |state|
      next false unless owner?(state, run_id, epoch) && state.status == "processing" && state.worker_accepting?
      run = state.current_run
      next false unless %w[dispatching moving].include?(run.status)
      attributes = { robot_events: run.robot_events + [ event ] }
      if event["event"] == "process_started"
        attributes[:robot_process] = event.slice("pid", "start_ticks", "group")
      elsif event["event"] == "command_sent"
        attributes.merge!(status: "moving", command_sent_at: run.command_sent_at || Time.current)
      elsif event["event"] == "completed"
        attributes[:motion_completed_at] = Time.current
      end
      run.update!(attributes)
      true
    end
  end

  def self.fail_enqueue!(run_id, epoch)
    locked do |state|
      next unless owner?(state, run_id, epoch)
      run = state.current_run
      if run.status == "queued" && run.started_at.nil?
        run.update!(status: "enqueue_failed", error_code: "enqueue_failed", finished_at: Time.current,
                    response_text: "受付できませんでした。もう一度お試しください。")
        state.update!(status: "idle", current_run_id: nil)
      else
        require_recovery!(state, "enqueue_result_unknown")
      end
    end
  end

  def self.fail_processing!(run_id, epoch)
    locked do |state|
      require_recovery!(state, "processing_failed") if owner?(state, run_id, epoch)
    end
  end

  def self.pause!
    locked do |state|
      state.update!(maintenance: true, worker_accepting: false, recovery_checked_at: nil)
      require_recovery!(state, "administrator_paused") if state.current_run_id
      state
    end
  end

  def self.owner?(state, run_id, epoch)
    state.current_run_id == run_id && state.worker_epoch == epoch
  end
  private_class_method :owner?

  def self.require_recovery!(state, reason)
    run = state.current_run
    if run && !%w[robot_failed recovery_required].include?(run.status)
      run.update!(status: "recovery_required", error_code: reason,
                  response_text: "処理の状態を確認できませんでした。再開前の確認が必要です。")
    end
    state.update!(status: "recovery_required")
  end
  private_class_method :require_recovery!
end
