require "test_helper"
require_relative "../support/robot_queue_test_support"

class RobotSubmissionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include RobotQueueTestSupport
  setup :prepare_test_worker
  teardown :restore_test_worker

  test "a busy reservation rejects a second browser before creating another record" do
    run = submit_test_run
    assert_no_difference "RobotRun.count" do
      error = assert_raises(RobotSubmission::Unavailable) { submit_test_run }
      assert_equal 409, error.http_status
    end
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_enqueued_jobs 1, only: ProcessInputJob
  end

  test "missing or stale workers reject work without creating queued records" do
    @test_worker.update!(last_heartbeat_at: 1.minute.ago)
    assert_no_difference "RobotRun.count" do
      error = assert_raises(RobotSubmission::Unavailable) { submit_test_run }
      assert_equal 503, error.http_status
    end
    assert_equal "idle", RobotState.singleton.status
    @test_worker.destroy!
    refute RobotState.singleton.worker_online?
  end

  test "enqueue failure makes any possibly delivered job inert before releasing" do
    adapter = Object.new
    adapter.define_singleton_method(:enqueue) { |_job| raise ActiveJob::EnqueueError, "injected failure" }
    adapter.define_singleton_method(:enqueue_at) { |*_args| raise "not used" }
    original = ProcessInputJob.queue_adapter
    ProcessInputJob.queue_adapter = adapter
    assert_raises(RobotSubmission::Unavailable) { submit_test_run }
    run = RobotRun.order(:id).last
    assert_equal "enqueue_failed", run.status
    assert_equal "idle", RobotState.singleton.status
    duplicate = ProcessInputJob.new(run.id, run.worker_epoch)
    duplicate.job_id = run.active_job_id
    duplicate.perform_now
    assert_nil run.reload.started_at
    assert_equal "enqueue_failed", run.status
  ensure
    ProcessInputJob.queue_adapter = original
  end

  test "ambiguous enqueue failure after execution starts requires recovery" do
    adapter = Object.new
    adapter.define_singleton_method(:enqueue) do |job|
      RobotState.claim!(job.arguments[0], job.job_id, job.arguments[1])
      raise ActiveJob::EnqueueError, "lost acknowledgement"
    end
    adapter.define_singleton_method(:enqueue_at) { |*_args| raise "not used" }
    original = ProcessInputJob.queue_adapter
    ProcessInputJob.queue_adapter = adapter
    assert_raises(RobotSubmission::Unavailable) { submit_test_run }
    run = RobotRun.order(:id).last
    assert run.started_at
    assert_equal "recovery_required", run.status
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_equal "recovery_required", RobotState.singleton.status
  ensure
    ProcessInputJob.queue_adapter = original
  end

  test "heartbeat loss and missing enqueue acknowledgement preserve ownership" do
    run = submit_test_run
    @test_worker.update!(last_heartbeat_at: 1.minute.ago)
    assert_equal "recovery_required", RobotState.reconcile!.status
    assert_equal "worker_unavailable", run.reload.error_code
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "unacknowledged enqueue and processing deadlines do not unlock the arm" do
    run = submit_test_run
    run.update!(queued_at: 30.seconds.ago, enqueued_at: nil)
    RobotState.reconcile!
    assert_equal "enqueue_unconfirmed", run.reload.error_code
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_nil run.started_at
  end

  test "a second healthy worker cannot replace the current worker" do
    replacement = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: Process.pid,
      hostname: Socket.gethostname, last_heartbeat_at: Time.current, metadata: { "queues" => "robot", "pool_size" => 1 })
    epoch = RobotState.singleton.worker_epoch
    assert_nil RobotState.register_worker!(replacement.id)
    assert_equal @test_worker.id, RobotState.singleton.worker_process_id
    assert_equal epoch, RobotState.singleton.worker_epoch
  end
end
