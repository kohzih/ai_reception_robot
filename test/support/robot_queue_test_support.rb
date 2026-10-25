module RobotQueueTestSupport
  def clear_robot_test_data
    RobotState.where(id: 1).update_all(current_run_id: nil)
    RobotState.delete_all
    RobotRun.delete_all
    SolidQueue::Job.delete_all
    SolidQueue::Process.delete_all
  end

  def prepare_test_worker
    @previous_worker_settings = %i[robot_worker_process_id robot_worker_epoch robot_preview_stage_seconds].to_h do |key|
      [ key, Rails.configuration.x.public_send(key) ]
    end
    Rails.configuration.x.robot_preview_stage_seconds = 0
    @test_worker = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid,
      pid: Process.pid, hostname: Socket.gethostname, last_heartbeat_at: Time.current,
      metadata: { "queues" => "robot", "pool_size" => 1 })
    epoch = RobotState.register_worker!(@test_worker.id)
    raise "Worker registration failed" unless epoch
    Rails.configuration.x.robot_worker_process_id = @test_worker.id
    Rails.configuration.x.robot_worker_epoch = epoch
    clear_enqueued_jobs
  end

  def restore_test_worker
    @previous_worker_settings&.each { |key, value| Rails.configuration.x.public_send("#{key}=", value) }
    clear_enqueued_jobs
  end

  def submit_test_run(scenario: "reception", browser_id: SecureRandom.uuid)
    RobotSubmission.call(browser_id: browser_id, attributes: { input_text: "受付はどこですか？", preview_scenario: scenario })
  end
end
