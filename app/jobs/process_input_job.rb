class ProcessInputJob < ApplicationJob
  queue_as :robot
  self.enqueue_after_transaction_commit = false

  def perform(run_id, epoch)
    return unless RobotState.claim!(run_id, job_id, epoch)
    run = RobotRun.find(run_id)
    begin
      run.preview? ? process_preview(run, epoch) : process_live(run, epoch)
    rescue StandardError
      RobotState.fail_processing!(run_id, epoch)
      raise
    end
  end

  private

  def process_preview(run, epoch)
    run_id = run.id
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
  end

  def process_live(run, epoch)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    factory = Rails.configuration.x.clef_client_factory || -> { ClefClient.new }
    classification = factory.call.classify(run.input_text)
    selection = ActionSelector.call(classification)
    raise ClefClient::Error.new("invalid_classification", "Invalid classification") unless selection.action
    attributes = {
      intent: classification.intent, confidence: classification.confidence,
      intent_probabilities: classification.probabilities, classification_model: classification.model,
      input_tokens: classification.input_tokens, selection_reason: selection.reason,
      classification_duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      action: selection.action, response_text: selection.message, error_code: nil
    }
    return unless RobotState.transition!(run.id, epoch, from: "classifying", to: "dispatching", attributes: attributes)
    executor = (Rails.configuration.x.robot_executor_factory || -> { RobotExecutor.new }).call
    result = executor.call(selection.action,
      launch_guard: ->(&block) { RobotState.with_dispatch_permission(run.id, epoch, &block) },
      continuing: -> { RobotState.execution_permitted?(run.id, epoch) }
    ) { |event| RobotState.record_event!(run.id, epoch, event) }
    run.reload
    success = result.success && result.exit_code == 0 && run.command_sent_at.present? && run.motion_completed_at.present?
    final = { robot_exit_code: result.exit_code, robot_duration_ms: result.duration_ms,
              error_code: success ? nil : (result.error_code || "completion_unconfirmed") }
    final[:response_text] = "動作の実行に失敗しました。" unless success
    RobotState.finish!(run.id, epoch, status: success ? "completed" : "robot_failed", attributes: final, release: success)
  rescue ClefClient::Error => error
    RobotState.finish!(run.id, epoch, status: "classification_failed",
      attributes: { error_code: error.code, response_text: ActionSelector.failure.message }, release: true)
  end
end
