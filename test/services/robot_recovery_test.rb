require "test_helper"
require "tmpdir"
require_relative "../support/robot_queue_test_support"

class RobotRecoveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include RobotQueueTestSupport
  setup do
    prepare_test_worker
    @directory = Pathname.new(Dir.mktmpdir("robot-recovery-test"))
    @latch = @directory.join("robot_recovery_required.json")
    @proof = { "ready" => true, "front" => true, "stopped" => true }
    @probe_calls = []
    probe = Object.new
    calls, proof, directory = @probe_calls, @proof, @directory
    probe.define_singleton_method(:call) do |**options|
      File.open(directory.join("robot_motion.lock"), "a") do |other|
        raise "Motion lock was released" if other.flock(File::LOCK_EX | File::LOCK_NB)
      end
      calls << options.except(:lock)
      proof.dup
    end
    @recovery = RobotRecovery.new(directory: @directory, probe: probe)
  end
  teardown do
    FileUtils.remove_entry(@directory)
    restore_test_worker
  end

  def pause_and_stop
    RobotState.pause!
    @test_worker.destroy!
  end

  test "pause atomically blocks submissions claims and new worker registration" do
    run = submit_test_run
    RobotState.pause!
    assert RobotState.singleton.maintenance?
    assert_equal "recovery_required", run.reload.status
    assert_raises(RobotSubmission::Unavailable) { submit_test_run }
    refute RobotState.claim!(run.id, run.active_job_id, run.worker_epoch)
    assert_nil RobotState.register_worker!(@test_worker.id)
    refute RobotScreenState.call(run.browser_id)[:available]
  end

  test "recovery checks workers and the explicitly selected run before the probe" do
    run = submit_test_run
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id) }
    RobotState.pause!
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id) }
    @test_worker.update!(last_heartbeat_at: 1.minute.ago)
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id) }
    @test_worker.destroy!
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id + 1) }
    assert_empty @probe_calls
    assert_equal run.id, RobotState.singleton.current_run_id
  end

  test "verified recovery revokes old jobs before release and resume requires fresh proof" do
    run = submit_test_run
    old_job, old_epoch = run.active_job_id, run.worker_epoch
    @latch.write("{}")
    pause_and_stop
    @recovery.recover(run_id: run.id, home: true)
    assert_equal "recovered", run.reload.status
    assert_equal old_job, run.recovery_details["invalidated_job_id"]
    assert_nil run.active_job_id
    assert run.recovered_at
    assert_nil run.command_sent_at
    assert_nil run.motion_completed_at
    assert RobotState.singleton.maintenance?
    assert_equal "idle", RobotState.singleton.status
    refute @latch.exist?
    @recovery.recover(resume: true)
    assert_equal 2, @probe_calls.length
    refute RobotState.singleton.maintenance?
    refute RobotState.singleton.worker_online?
    prepare_test_worker
    next_run = submit_test_run
    duplicate = ProcessInputJob.new(run.id, old_epoch)
    duplicate.job_id = old_job
    duplicate.perform_now
    assert_equal "recovered", run.reload.status
    assert_equal next_run.id, RobotState.singleton.current_run_id
    assert_equal "queued", next_run.reload.status
  end

  test "unconfirmed physics preserves the latch reservation and reception stop" do
    run = submit_test_run
    @latch.write("{}")
    pause_and_stop
    @proof["front"] = false
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id) }
    assert_equal "recovery_required", run.reload.status
    assert_equal run.id, RobotState.singleton.current_run_id
    assert @latch.exist?
    assert RobotState.singleton.maintenance?
  end

  test "filesystem failure stays fenced and an explicit retry can finish recovery" do
    run = submit_test_run
    pause_and_stop
    @latch.mkdir
    @latch.join("cannot-unlink").write("failure injection")
    assert_raises(RobotRecovery::Error) { @recovery.recover(run_id: run.id) }
    assert_nil run.reload.active_job_id
    assert_equal run.id, RobotState.singleton.current_run_id
    assert RobotState.singleton.maintenance?
    @latch.join("cannot-unlink").unlink
    @latch.rmdir
    @recovery.recover(run_id: run.id)
    assert_nil RobotState.singleton.current_run_id
    assert_equal "recovered", run.reload.status
  end

  test "a concurrent administrator cannot enter the recovery section" do
    pause_and_stop
    File.open(@directory.join("robot_admin.lock"), "a") do |other|
      other.flock(File::LOCK_EX | File::LOCK_NB)
      assert_raises(RobotRecovery::Error) { @recovery.recover }
    end
    assert_empty @probe_calls
  end

  test "queued Solid Queue deliveries are discarded after the record is revoked" do
    original = ProcessInputJob.queue_adapter
    ProcessInputJob.queue_adapter = :solid_queue
    run = submit_test_run
    job = SolidQueue::Job.find_by!(active_job_id: run.active_job_id)
    assert job.ready_execution
    pause_and_stop
    @recovery.recover(run_id: run.id)
    assert_nil SolidQueue::Job.find_by(id: job.id)
    assert_equal "recovered", run.reload.status
    assert_nil RobotState.singleton.current_run_id
  ensure
    ProcessInputJob.queue_adapter = original
  end

  test "resume cannot skip a pending recovery and orphaned queued records are revoked" do
    run = submit_test_run
    pause_and_stop
    assert_raises(RobotRecovery::Error) { @recovery.recover(resume: true) }
    orphan = RobotRun.create!(browser_id: SecureRandom.uuid, input_text: "orphan", preview_scenario: "greeting")
    @recovery.recover(run_id: run.id)
    assert_equal "recovered", orphan.reload.status
    assert_nil orphan.active_job_id
  end

  test "process termination checks its identity and never releases the reservation" do
    run = submit_test_run
    pause_and_stop
    assert_raises(RobotRecovery::Error) { @recovery.stop_process(run_id: run.id) }
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true)
    identity = RobotProcessIdentity.read(pid)
    run.update!(robot_process: identity.merge("start_ticks" => "wrong"))
    assert_raises(RobotRecovery::Error) { @recovery.stop_process(run_id: run.id) }
    assert RobotProcessIdentity.matches?(identity)
    run.update!(robot_process: identity)
    result = @recovery.stop_process(run_id: run.id)
    assert_equal true, result["process_exited"]
    assert_equal false, result["robot_stop_confirmed"]
    assert_equal run.id, RobotState.singleton.current_run_id
    assert_equal "recovery_required", run.reload.status
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  test "a dead worker's claimed delivery is finalized before it is discarded" do
    original = ProcessInputJob.queue_adapter
    ProcessInputJob.queue_adapter = :solid_queue
    run = submit_test_run
    job = SolidQueue::Job.find_by!(active_job_id: run.active_job_id)
    job.ready_execution.destroy!
    SolidQueue::ClaimedExecution.create!(job: job, process: @test_worker)
    pause_and_stop
    @recovery.recover(run_id: run.id)
    assert_nil SolidQueue::Job.find_by(id: job.id)
    assert_equal "recovered", run.reload.status
    assert RobotState.singleton.maintenance?
  ensure
    ProcessInputJob.queue_adapter = original
  end

  test "resume after a simulator restart still asks for fresh stopped physics" do
    pause_and_stop
    @recovery.recover(resume: true, after_restart: true)
    assert_equal({ home: false, after_restart: true }, @probe_calls.last)
    refute RobotState.singleton.maintenance?
    refute RobotState.singleton.worker_online?
  end
end
