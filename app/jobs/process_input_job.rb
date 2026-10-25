class ProcessInputJob < ApplicationJob
  queue_as :robot
  self.enqueue_after_transaction_commit = false

  def perform(run_id, epoch)
    return unless RobotState.claim!(run_id, job_id, epoch)
    run = RobotRun.find(run_id)
    begin
      sleep Rails.configuration.x.robot_preview_stage_seconds
      attributes = PreviewResponse.attributes_for(run.preview_scenario).except(:status)
      if run.preview_scenario == "classification_error"
        RobotState.finish!(run_id, epoch, status: "classification_failed", attributes: attributes, release: true)
        return
      end
      return unless RobotState.transition!(run_id, epoch, from: "classifying", to: "dispatching", attributes: attributes)
      sleep Rails.configuration.x.robot_preview_stage_seconds
      failed = run.preview_scenario == "robot_error"
      RobotState.finish!(run_id, epoch, status: failed ? "robot_failed" : "previewed", attributes: attributes, release: !failed)
    rescue StandardError
      RobotState.fail_processing!(run_id, epoch)
      raise
    end
  end
end
