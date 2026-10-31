require "io/console"
require "json"
require "optparse"

options = { variant: nil, dataset: "tuning", interactive: false }
parser = OptionParser.new do |opts|
  opts.banner = "使い方: bin/rails runner scripts/verify_clef.rb -- [--interactive] [--dataset tuning|holdout] [--variant both|baseline|revised]"
  opts.on("--interactive", "認証情報を対話入力する。トークンは非表示で、保存しない。") { options[:interactive] = true }
  opts.on("--variant NAME", %w[both baseline revised], "比較対象（既定: tuningはboth、holdoutはrevised）") { |value| options[:variant] = value }
  opts.on("--dataset NAME", %w[tuning holdout], "tuning: 既存15文、holdout: 未使用20文（既定はrevisedだけ）") { |value| options[:dataset] = value }
  opts.on("-h", "--help", "使い方を表示") { puts opts; exit 0 }
end

begin
  ARGV.shift if ARGV.first == "--"
  parser.parse!(ARGV)
  raise OptionParser::InvalidArgument, "不要な引数があります。" if ARGV.any?

  account_id, api_token = ENV["CLOUDFLARE_ACCOUNT_ID"], ENV["CLOUDFLARE_API_TOKEN"]
  if options[:interactive]
    console = IO.console
    raise ClefClient::Error.new("configuration_error", "対話入力にはコンテナ内のターミナルが必要です。") unless console
    console.print "Cloudflare Account ID: "
    console.flush
    account_id = console.gets&.strip
    console.print "Workers AI API token（非表示）: "
    console.flush
    begin
      api_token = console.noecho(&:gets)&.strip
    ensure
      console.puts
    end
  end
  # Validate before creating an evaluation folder or sending any request.
  ClefClient.new(account_id: account_id, api_token: api_token)
  variant = options[:variant] || (options[:dataset] == "holdout" ? "revised" : "both")
  variants = variant == "both" ? %w[baseline revised] : [ variant ]
  evaluation = ClefEvaluation.new(variants: variants, dataset: options[:dataset], client_factory: ->(question) {
    ClefClient.new(account_id: account_id, api_token: api_token, question: question)
  })
  puts "ロボットへの指令は送りません。#{evaluation.dataset}の#{evaluation.request_count}回のAPI呼び出しを順番に実行します。"
  puts "結果の保存先: #{evaluation.directory}"
  $stdout.flush
  evaluation.run { |record| puts JSON.generate(record); $stdout.flush }
  puts JSON.pretty_generate(evaluation.summary)
  if evaluation.summary[:complete]
    puts "実測記録を保存しました。誤分類はsummary.jsonとresults.jsonlを確認してください。"
    exit 0
  else
    warn "APIエラーで比較を停止しました。途中までの結果と未実行の入力も保存しています。"
    exit 2
  end
rescue ClefClient::Error => error
  warn "#{error.code}: #{error.message}"
  exit 1
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 1
rescue Interrupt
  warn "検証を中断しました。開始済みの記録は保存先を確認してください。"
  exit 130
end
