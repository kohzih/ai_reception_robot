require "json"
require "open3"

class RobotRecoveryProbe
  class Error < StandardError; end

  def initialize(process_factory: Open3.method(:popen3), timeout: 45, termination_grace: 8)
    @process_factory, @timeout, @termination_grace = process_factory, timeout, termination_grace
  end

  def call(lock:, home:, after_restart:)
    raise Error, "python_configuration_error" unless ENV["ROBOT_PYTHON"] == RobotExecutor::PYTHON
    nonce = SecureRandom.hex(16)
    command = [ RobotExecutor::PYTHON, "-u", Rails.root.join("scripts/robot/recovery.py").to_s,
                "--lock-fd", "3", "--nonce", nonce ]
    command << "--home" if home
    command << "--after-simulator-restart" if after_restart
    input, output, errors, waiter = @process_factory.call(
      { "CLOUDFLARE_ACCOUNT_ID" => nil, "CLOUDFLARE_API_TOKEN" => nil },
      *command, 3 => lock, pgroup: true, chdir: Rails.root.to_s
    )
    input.close
    streams, captured, sizes = [ output, errors ], +"".b, Hash.new(0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
    until streams.empty? && !waiter.alive?
      raise Error, "recovery_timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      if streams.empty?
        sleep 0.02
        next
      end
      (IO.select(streams, nil, nil, 0.05)&.first || []).each do |stream|
        chunk = stream.read_nonblock(4096, exception: false)
        next if chunk == :wait_readable
        if chunk.nil?
          streams.delete(stream)
          next
        end
        sizes[stream] += chunk.bytesize
        raise Error, "recovery_output_limit" if sizes[stream] > 65_536
        captured << chunk if stream == output
      end
    end
    event = captured.force_encoding("UTF-8").lines.map { |line| JSON.parse(line) }.last
    unless waiter.value.success? && event.is_a?(Hash) && event["event"] == "recovery_verified" && event["nonce"] == nonce
      code = event.is_a?(Hash) && event["code"].to_s.match?(/\A[a-z0-9_]{1,64}\z/) ? event["code"] : "recovery_unconfirmed"
      raise Error, code
    end
    event.except("nonce", "event")
  rescue JSON::ParserError, EncodingError
    raise Error, "invalid_recovery_response"
  rescue SystemCallError, IOError
    raise Error, "recovery_process_error"
  ensure
    if waiter&.alive?
      Process.kill("TERM", -waiter.pid) rescue nil
      unless waiter.join(@termination_grace)
        Process.kill("KILL", -waiter.pid) rescue nil
        waiter.join(2)
      end
    end
    [ input, output, errors ].compact.each { |io| io.close unless io.closed? }
  end
end
