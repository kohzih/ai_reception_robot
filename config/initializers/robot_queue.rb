SolidQueue.process_heartbeat_interval = 2.seconds
Rails.application.config.x.robot_preview_stage_seconds = 2.0
Rails.application.config.x.clef_client_factory = nil
Rails.application.config.x.robot_executor_factory = nil
Rails.application.config.x.reception_mode = ENV.fetch("RECEPTION_MODE", "live")
unless %w[live preview].include?(Rails.application.config.x.reception_mode)
  raise ArgumentError, "RECEPTION_MODE must be live or preview"
end

SolidQueue.on_worker_start do |worker|
  if worker.queues == [ "robot" ] && worker.pool.size == 1 && (epoch = RobotState.register_worker!(worker.process_id))
    Rails.application.config.x.robot_worker_process_id = worker.process_id
    Rails.application.config.x.robot_worker_epoch = epoch
  else
    worker.stop
  end
end
SolidQueue.on_worker_stop { |worker| RobotState.stop_accepting!(worker.process_id) }
SolidQueue.on_worker_exit { |worker| RobotState.unregister_worker!(worker.process_id) }
