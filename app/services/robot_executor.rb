require "json"
require "open3"

class RobotExecutor
  PYTHON = "/usr/bin/python3".freeze
  SCRIPTS = %w[bow reception hall hold].to_h { |name| [ name, Rails.root.join("scripts/robot/#{name}.py").to_s.freeze ] }.freeze
  STAGES = {
    "bow" => %w[front bow return], "reception" => %w[front turn bow upright return],
    "hall" => %w[front turn bow upright return], "hold" => %w[front open_ready close_1 open_1 close_2 open_2]
  }.freeze
  # Includes the Python motion limit (30s), cancellation and process teardown.
  DEADLINES = { "bow" => 40, "reception" => 45, "hall" => 45, "hold" => 45 }.freeze
  MAX_STREAM_BYTES = 65_536
  MAX_LINE_BYTES = 8_192
  Result = Data.define(:success, :error_code, :exit_code, :duration_ms)
  class Failure < StandardError
    attr_reader :code
    def initialize(code)
      @code = code
      super(code)
    end
  end

  def initialize(process_factory: Open3.method(:popen3), timeout: nil, termination_grace: 8)
    @process_factory, @timeout, @termination_grace = process_factory, timeout, termination_grace
  end

  def call(action, launch_guard: ->(&block) { block.call }, continuing: -> { true }, &on_event)
    @action, @on_event = action, on_event
    @stdin = @stdout = @stderr = @waiter = @exit_code = @failure_code = nil
    @started = monotonic
    @stage_index, @pending, @terminal, @began = 0, nil, nil, false
    raise Failure, "invalid_action" unless SCRIPTS.key?(action)
    unless ENV["ROBOT_PYTHON"] == PYTHON && File.executable?(PYTHON) && File.file?(SCRIPTS.fetch(action))
      raise Failure, "python_configuration_error"
    end
    child = launch_guard.call do
      @process_factory.call(
        { "CLOUDFLARE_ACCOUNT_ID" => nil, "CLOUDFLARE_API_TOKEN" => nil, "PYTHONUNBUFFERED" => "1" },
        PYTHON, "-u", SCRIPTS.fetch(action), pgroup: true, chdir: Rails.root.to_s
      )
    end
    raise Failure, "reservation_lost" unless child
    @stdin, @stdout, @stderr, @waiter = child
    @stdin.close
    read_process(continuing)
    status = @waiter.value
    @exit_code = status.exitstatus
    raise Failure, @failure_code if @failure_code
    raise Failure, "process_failed" unless status.success?
    raise Failure, "completion_unconfirmed" unless @terminal == "completed"
    result(true, nil)
  rescue Failure => error
    terminate_process
    result(false, error.code)
  rescue SystemCallError, IOError
    terminate_process
    result(false, "process_io_error")
  rescue StandardError
    terminate_process
    result(false, "event_processing_failed")
  ensure
    [ @stdin, @stdout, @stderr ].compact.each { |io| io.close unless io.closed? }
  end

  private

  def read_process(continuing)
    streams = [ @stdout, @stderr ]
    bytes = Hash.new(0)
    buffer = +"".b
    deadline = @started + (@timeout || DEADLINES.fetch(@action))
    next_guard = 0
    until streams.empty? && !@waiter.alive?
      raise Failure, "process_timeout" if monotonic >= deadline
      if monotonic >= next_guard
        raise Failure, "reservation_lost" unless continuing.call
        next_guard = monotonic + 0.2
      end
      if streams.empty?
        sleep 0.02
        next
      end
      ready = IO.select(streams, nil, nil, 0.05)&.first || []
      ready.each do |io|
        chunk = io.read_nonblock(4096, exception: false)
        next if chunk == :wait_readable
        if chunk.nil?
          streams.delete(io)
          next
        end
        bytes[io] += chunk.bytesize
        raise Failure, "output_limit" if bytes[io] > MAX_STREAM_BYTES
        next unless io == @stdout
        buffer << chunk
        while (line_end = buffer.index("\n"))
          line = buffer.slice!(0, line_end + 1)
          raise Failure, "output_limit" if line.bytesize > MAX_LINE_BYTES
          accept_event(line)
        end
        raise Failure, "output_limit" if buffer.bytesize > MAX_LINE_BYTES
      end
    end
    raise Failure, "invalid_event" unless buffer.empty?
  end

  def accept_event(line)
    event = JSON.parse(line.force_encoding("UTF-8"))
    unless event.is_a?(Hash) && event["motion"] == @action &&
        event["elapsed_sec"].is_a?(Numeric) && event["elapsed_sec"].finite? && event["elapsed_sec"] >= 0 && !@terminal
      raise Failure, "invalid_event"
    end
    case event["event"]
    when "started"
      raise Failure, "invalid_event" if @began
      @began = true
    when "command_sent"
      unless @began && !@pending && event["stage"] == STAGES.fetch(@action)[@stage_index] &&
          event["goal_id"].is_a?(String) && event["goal_id"].match?(/\A[0-9a-f]{32}\z/) && valid_controller?(event)
        raise Failure, "invalid_event"
      end
      @pending = event["stage"]
    when "stage_completed"
      unless @pending && event["stage"] == @pending && event["action_status"] == 4 && event["result_error_code"] == 0
        raise Failure, "invalid_event"
      end
      @pending = nil
      @stage_index += 1
    when "completed"
      raise Failure, "completion_unconfirmed" unless @began && !@pending && @stage_index == STAGES.fetch(@action).length
      @terminal = "completed"
    when "cancel_requested", "stop_confirmed"
      raise Failure, "invalid_event" unless @began
    when "failed"
      raise Failure, "invalid_event" unless event["code"].is_a?(String) && event["code"].match?(/\A[a-z0-9_]{1,64}\z/)
      @terminal = "failed"
    else
      raise Failure, "invalid_event"
    end
    # Retain only protocol fields; Python stderr and arbitrary text stay out of the DB.
    stored = event.slice("event", "motion", "elapsed_sec", "stage", "controller", "goal_id",
                         "action_status", "result_error_code", "code", "requires_recovery", "stop_confirmed")
    raise Failure, "reservation_lost" if @on_event && !@on_event.call(stored)
    @failure_code = "robot_#{event['code']}" if @terminal == "failed"
  rescue JSON::ParserError, EncodingError
    raise Failure, "invalid_event"
  end

  def valid_controller?(event)
    expected = @action == "hold" && event["stage"] != "front" ? "gripper" : "arm"
    event["controller"] == expected
  end

  def terminate_process
    return unless @waiter
    if @waiter.alive?
      signal_group("TERM")
      unless @waiter.join(@termination_grace)
        signal_group("KILL")
        @waiter.join(2)
      end
    end
    @exit_code = @waiter.value.exitstatus unless @waiter.alive?
  end

  def signal_group(signal)
    Process.kill(signal, -@waiter.pid)
  rescue Errno::ESRCH
    nil
  end

  def result(success, code)
    Result.new(success: success, error_code: code, exit_code: @exit_code, duration_ms: ((monotonic - @started) * 1000).round)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
