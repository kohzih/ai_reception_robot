SolidQueue.process_heartbeat_interval = 2.seconds
Rails.application.config.x.robot_preview_stage_seconds = 2.0

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
