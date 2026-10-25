require "test_helper"
require_relative "../support/robot_queue_test_support"

class RobotConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActiveJob::TestHelper
  include RobotQueueTestSupport

  setup do
    clear_robot_test_data
    prepare_test_worker
  end
  teardown do
    restore_test_worker
    clear_robot_test_data
  end

  test "two simultaneous database connections can reserve only one run" do
    ready, start, outcomes = Queue.new, Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            outcomes << [ :accepted, submit_test_run.id ]
          rescue RobotSubmission::Unavailable => error
            outcomes << [ :rejected, error.http_status ]
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:value)
    results = 2.times.map { outcomes.pop }
    assert_equal 1, results.count { |item| item.first == :accepted }
    assert_includes results, [ :rejected, 409 ]
    assert_equal 1, RobotRun.count
    assert_equal RobotRun.first.id, RobotState.singleton.current_run_id
    assert_enqueued_jobs 1, only: ProcessInputJob
  end
end
