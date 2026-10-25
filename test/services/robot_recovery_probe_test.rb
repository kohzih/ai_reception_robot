require "test_helper"
require "tmpdir"

class RobotRecoveryProbeTest < ActiveSupport::TestCase
  setup do
    @previous_python = ENV["ROBOT_PYTHON"]
    ENV["ROBOT_PYTHON"] = RobotExecutor::PYTHON
    @directory = Pathname.new(Dir.mktmpdir("robot-probe-test"))
    @lock = File.open(@directory.join("motion.lock"), "a")
    @lock.flock(File::LOCK_EX | File::LOCK_NB)
  end
  teardown do
    @lock.close
    FileUtils.remove_entry(@directory)
    ENV["ROBOT_PYTHON"] = @previous_python
  end

  def probe(variant, **settings)
    factory = ->(environment, *command, **options) do
      nonce = command[command.index("--nonce") + 1]
      Open3.popen3(environment, RbConfig.ruby, Rails.root.join("test/support/recovery_probe_fixture.rb").to_s,
                  variant, nonce, **options)
    end
    RobotRecoveryProbe.new(process_factory: factory, termination_grace: 0.1, **settings)
  end

  test "the verified response is nonce bound and the parent keeps its motion lock" do
    result = probe("success").call(lock: @lock, home: false, after_restart: false)
    assert_equal true, result["ready"]
    File.open(@lock.path, "a") { |other| refute other.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  test "wrong nonce nonzero exit and excessive output cannot verify recovery" do
    %w[wrong_nonce nonzero flood].each do |variant|
      assert_raises(RobotRecoveryProbe::Error) { probe(variant).call(lock: @lock, home: true, after_restart: false) }
    end
  end

  test "a stalled probe is terminated and stays within its deadline" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(RobotRecoveryProbe::Error) do
      probe("hang", timeout: 0.3).call(lock: @lock, home: false, after_restart: false)
    end
    assert_equal "recovery_timeout", error.message
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end
end
