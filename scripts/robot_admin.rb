require "optparse"

ARGV.shift if ARGV.first == "--"
operation = ARGV.shift
options = { run_id: nil, home: false, after_restart: false }
parser = OptionParser.new do |opts|
  opts.banner = "使い方: bin/rails runner scripts/robot_admin.rb -- status|pause|stop-process|recover|resume [options]"
  opts.on("--run-id ID", Integer, "現在の実行IDを指定する") { |value| options[:run_id] = value }
  opts.on("--home", "停止確認後に正面・グリッパー開きへ戻す") { options[:home] = true }
  opts.on("--after-simulator-restart", "Gazeboを再起動した後だけ指定する") { options[:after_restart] = true }
end
begin
  parser.parse!(ARGV)
  raise OptionParser::InvalidArgument, "不要な引数があります。" if ARGV.any?
  if %w[status pause].include?(operation) && options.values.any?
    raise OptionParser::InvalidArgument, "statusとpauseに追加オプションは指定できません。"
  end
  result = case operation
  when "status" then RobotRecovery.status
  when "pause" then RobotState.pause!; RobotRecovery.status
  when "recover" then RobotRecovery.new.recover(**options)
  when "stop-process"
    raise OptionParser::InvalidArgument, "--run-idを指定してください。" unless options[:run_id]
    raise OptionParser::InvalidArgument, "stop-processにはrun-idだけを指定してください。" if options[:home] || options[:after_restart]
    RobotRecovery.new.stop_process(run_id: options[:run_id])
  when "resume"
    raise OptionParser::InvalidArgument, "resumeにはrun-idとhomeを指定できません。" if options[:run_id] || options[:home]
    RobotRecovery.new.recover(resume: true, after_restart: options[:after_restart])
  else raise OptionParser::InvalidArgument, "操作を指定してください。"
  end
  puts JSON.pretty_generate(result)
rescue RobotRecovery::Error, OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 1
end
