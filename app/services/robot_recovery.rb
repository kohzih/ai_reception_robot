require "socket"

class RobotRecovery
  class Error < StandardError; end

  def initialize(directory: Rails.root.join("tmp"), probe: RobotRecoveryProbe.new)
    @directory, @probe = Pathname.new(directory), probe
  end

  def self.status
    state = RobotState.reconcile!
    {
      state: state.attributes.slice("status", "maintenance", "current_run_id", "worker_accepting", "recovery_checked_at"),
      run: state.current_run&.attributes&.slice("id", "status", "action", "error_code", "command_sent_at", "finished_at", "robot_events", "robot_process"),
      queue_processes: SolidQueue::Process.all.map { |process| process.attributes.slice("id", "kind", "pid", "hostname", "last_heartbeat_at") },
      python_recovery_latch: Rails.root.join("tmp/robot_recovery_required.json").exist?
    }
  end

  def stop_process(run_id:)
    @directory.mkpath
    with_lock("robot_admin.lock") do
      state = RobotState.singleton
      raise Error, "pauseと現在の実行IDを確認してください。" unless state.maintenance? && state.current_run_id == run_id
      ensure_workers_stopped!
      saved = state.current_run.robot_process
      unless saved["pid"].is_a?(Integer) && saved["start_ticks"].is_a?(String)
        raise Error, "Pythonプロセスの識別情報がありません。状態確認またはシミュレータ再起動が必要です。"
      end
      current = RobotProcessIdentity.read(saved["pid"])
      return { "already_exited" => true } if current.nil? || current["state"] == "Z"
      raise Error, "Pythonプロセスの識別情報が一致しません。" unless RobotProcessIdentity.matches?(saved)
      Process.kill("TERM", -saved.fetch("pid"))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
      sleep 0.05 while RobotProcessIdentity.matches?(saved) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      if RobotProcessIdentity.matches?(saved)
        Process.kill("KILL", -saved.fetch("pid"))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.02 while RobotProcessIdentity.matches?(saved) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      end
      raise Error, "プロセスの終了を確認できません。" if RobotProcessIdentity.matches?(saved)
      { "process_exited" => true, "robot_stop_confirmed" => false }
    end
  end

  def recover(run_id: nil, home: false, after_restart: false, resume: false)
    @directory.mkpath
    with_lock("robot_admin.lock") do
      snapshot = RobotState.singleton
      raise Error, "先にpauseで受付を停止してください。" unless snapshot.maintenance?
      if resume && snapshot.current_run_id
        raise Error, "先に実行IDを指定してrecoverしてください。"
      end
      unless snapshot.current_run_id == run_id
        raise Error, "現在の実行IDを明示してください。履歴の別実行は変更できません。"
      end
      ensure_workers_stopped!
      with_lock("robot_motion.lock") do |motion_lock|
        details = @probe.call(lock: motion_lock, home: home, after_restart: after_restart)
        unless %w[ready front stopped].all? { |key| details[key] == true }
          raise Error, "正面姿勢と停止を確認できませんでした。"
        end
        ensure_workers_stopped!
        fence, jobs, recovered_ids = SecureRandom.uuid, [], []
        RobotState.locked do |state|
          assert_snapshot!(state, snapshot)
          runs = RobotRun.where(status: RobotRun::ACTIVE_STATUSES).to_a
          runs << state.current_run if state.current_run
          runs.compact.uniq(&:id).each do |run|
            old_job_id = run.active_job_id || run.recovery_details["invalidated_job_id"]
            jobs << old_job_id if old_job_id
            recovered_ids << run.id
            audit = run.recovery_details.merge(details).merge(
              "previous_status" => run.recovery_details["previous_status"] || run.status,
              "invalidated_job_id" => old_job_id
            )
            run.update!(status: "recovered", active_job_id: nil, worker_epoch: nil, recovered_at: Time.current,
                        recovery_details: audit, finished_at: run.finished_at || Time.current,
                        response_text: run.response_text.presence || "復帰を確認しました。")
          end
          state.update!(worker_epoch: fence, worker_process_id: nil, worker_accepting: false)
        end
        # Fencing is committed before touching the separate queue DB or latch.
        SolidQueue::Job.where(queue_name: "robot", class_name: "ProcessInputJob", active_job_id: jobs).each do |job|
          # A dead worker can leave a claimed delivery. Finalize that claim only
          # after stopped-worker and physics verification, with fencing committed.
          job.claimed_execution&.failed_with(StandardError.new("Invalidated after verified administrator recovery"))
          job.reload.discard
        end
        latch = @directory.join("robot_recovery_required.json")
        latch.unlink if latch.exist?
        RobotState.locked do |state|
          unless state.maintenance? && state.current_run_id == run_id && state.worker_epoch == fence
            raise Error, "復帰中に利用状態が変わりました。受付停止を維持します。"
          end
          state.update!(status: "idle", current_run_id: nil, worker_epoch: nil,
                        recovery_checked_at: Time.current, maintenance: !resume)
        end
        details.merge("recovered_run_ids" => recovered_ids, "invalidated_job_ids" => jobs, "maintenance" => !resume)
      end
    end
  rescue RobotRecoveryProbe::Error => error
    raise Error, "復帰確認に失敗しました: #{error.message}"
  rescue SystemCallError, ActiveRecord::ActiveRecordError
    raise Error, "復帰の保存またはジョブ無効化に失敗しました。受付停止を維持します。"
  end

  private

  def with_lock(name)
    File.open(@directory.join(name), File::RDWR | File::CREAT, 0o600) do |file|
      raise Error, "別の管理操作またはPython動作が実行中です。" unless file.flock(File::LOCK_EX | File::LOCK_NB)
      yield file
    end
  end

  def ensure_workers_stopped!
    running = SolidQueue::Process.where(kind: "Worker").any? do |process|
      process.last_heartbeat_at > RobotState::HEARTBEAT_TIMEOUT.ago ||
        (process.hostname == Socket.gethostname && process_alive?(process.pid))
    end
    raise Error, "ワーカーを停止してから復帰してください。" if running
  end

  def process_alive?(pid)
    process = RobotProcessIdentity.read(pid)
    process.present? && process["state"] != "Z"
  rescue Errno::EPERM, Errno::EACCES
    true
  end

  def assert_snapshot!(state, snapshot)
    unless state.maintenance? && state.current_run_id == snapshot.current_run_id && state.worker_epoch == snapshot.worker_epoch
      raise Error, "利用状態が変わったため復帰を中止しました。"
    end
  end
end
