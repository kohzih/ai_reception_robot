class RobotProcessIdentity
  def self.read(pid)
    return unless pid.is_a?(Integer) && pid > 1
    fields = File.read("/proc/#{pid}/stat").split(") ", 2).last.split
    { "pid" => pid, "start_ticks" => fields.fetch(19), "state" => fields.fetch(0), "group" => fields.fetch(2).to_i }
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def self.matches?(saved)
    current = read(saved["pid"])
    current && current["state"] != "Z" && current["start_ticks"] == saved["start_ticks"] && current["group"] == saved["pid"]
  end
end
