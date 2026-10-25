require "test_helper"
require_relative "../support/robot_queue_test_support"

class ProcessInputJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include RobotQueueTestSupport
  setup :prepare_test_worker
  teardown :restore_test_worker

  test "successful jobs preserve timestamps and release only after finishing" do
    run = submit_test_run
    assert_equal "queued", run.status
    assert_equal run.id, RobotState.singleton.current_run_id
    assert run.enqueued_at
    perform_enqueued_jobs
    run.reload
    assert_equal "previewed", run.status
    assert_equal "受付の方向を示します。", run.response_text
    assert run.started_at
    assert run.finished_at
    assert_operator run.finished_at, :>=, run.started_at
    assert_equal "idle", RobotState.singleton.status
    assert_nil RobotState.singleton.current_run_id
    assert run.preview?
  end

  test "duplicate delivery and forged job ids cannot repeat a run" do
    run = submit_test_run
    forged = ProcessInputJob.new(run.id, run.worker_epoch)
    forged.perform_now
    assert_equal "queued", run.reload.status
    perform_enqueued_jobs
    finished = run.reload.finished_at
    duplicate = ProcessInputJob.new(run.id, run.worker_epoch)
    duplicate.job_id = run.active_job_id
    duplicate.perform_now
    assert_equal finished, run.reload.finished_at
    assert_equal "idle", RobotState.singleton.status
  end

  test "classification failure releases the reservation but robot failure keeps it" do
    run = submit_test_run(scenario: "classification_error")
    perform_enqueued_jobs
    assert_equal "classification_failed", run.reload.status
    assert_nil run.action
    assert_equal "idle", RobotState.singleton.status
    failed = submit_test_run(scenario: "robot_error")
    perform_enqueued_jobs
    assert_equal "robot_failed", failed.reload.status
    assert_equal "recovery_required", RobotState.singleton.status
    assert_equal failed.id, RobotState.singleton.current_run_id
    assert_raises(RobotSubmission::Unavailable) { submit_test_run }
  end

  test "unstarted jobs expire without replaying or unlocking" do
    run = submit_test_run
    run.update!(queued_at: 30.seconds.ago)
    perform_enqueued_jobs
    assert_equal "recovery_required", run.reload.status
    assert_nil run.started_at
    assert_equal "recovery_required", RobotState.singleton.status
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "worker restart fences both queued and executing records" do
    run = submit_test_run
    old_epoch = run.worker_epoch
    @test_worker.destroy!
    replacement = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
      hostname: Socket.gethostname, last_heartbeat_at: Time.current, metadata: { "queues" => "robot", "pool_size" => 1 })
    new_epoch = RobotState.register_worker!(replacement.id)
    refute_equal old_epoch, new_epoch
    assert_equal "recovery_required", run.reload.status
    Rails.configuration.x.robot_worker_process_id = replacement.id
    Rails.configuration.x.robot_worker_epoch = new_epoch
    perform_enqueued_jobs
    assert_nil run.reload.started_at
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_equal "recovery_required", RobotState.singleton.status
  end

  test "a restart during execution rejects late results from the old worker" do
    run = submit_test_run
    assert RobotState.claim!(run.id, run.active_job_id, run.worker_epoch)
    @test_worker.destroy!
    replacement = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
      hostname: Socket.gethostname, last_heartbeat_at: Time.current, metadata: { "queues" => "robot", "pool_size" => 1 })
    RobotState.register_worker!(replacement.id)
    assert_equal "recovery_required", run.reload.status
    refute RobotState.finish!(run.id, run.worker_epoch, status: "previewed", attributes: { response_text: "late result" }, release: true)
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_nil run.reload.finished_at
  end

  test "a stuck processing record remains reserved for explicit recovery" do
    run = submit_test_run
    assert RobotState.claim!(run.id, run.active_job_id, run.worker_epoch)
    run.update!(started_at: 3.minutes.ago)
    assert_equal "recovery_required", RobotState.reconcile!.status
    assert_equal "processing_timeout", run.reload.error_code
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "an unexpected processing exception is not retried and keeps the reservation" do
    run = submit_test_run
    Rails.configuration.x.robot_preview_stage_seconds = -1
    job = ProcessInputJob.new(run.id, run.worker_epoch)
    job.job_id = run.active_job_id
    assert_raises(ArgumentError) { job.perform_now }
    assert_equal "recovery_required", run.reload.status
    assert_equal "processing_failed", run.error_code
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_enqueued_jobs 1, only: ProcessInputJob
  end

  test "a new boot always creates a new epoch even if a process id is reused" do
    run = submit_test_run
    old_epoch = run.worker_epoch
    refute_equal old_epoch, RobotState.register_worker!(@test_worker.id)
    perform_enqueued_jobs
    assert_equal "recovery_required", run.reload.status
    assert_nil run.started_at
    assert_equal run.id, RobotState.singleton.current_run_id
  end
end
