require_relative "robot_queue_test_support"

module RobotSystemWorker
  include RobotQueueTestSupport

  def start_system_worker
    clear_robot_test_data
    @previous_adapter = ProcessInputJob.queue_adapter
    @previous_delay = Rails.configuration.x.robot_preview_stage_seconds
    ProcessInputJob.queue_adapter = :solid_queue
    Rails.configuration.x.robot_preview_stage_seconds = 0.2
    @system_worker = SolidQueue::Worker.new(queues: [ "robot" ], threads: 1, polling_interval: 0.05, mode: :async)
    @system_worker.start
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until RobotState.singleton.worker_online? && RobotState.singleton.worker_process_id == @system_worker.process_id
      raise "Worker did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def stop_system_worker
    visit "about:blank"
    @system_worker&.stop
    ProcessInputJob.queue_adapter = @previous_adapter if @previous_adapter
    Rails.configuration.x.robot_preview_stage_seconds = @previous_delay
    Rails.configuration.x.robot_worker_process_id = nil
    Rails.configuration.x.robot_worker_epoch = nil
    clear_robot_test_data
  end
end
