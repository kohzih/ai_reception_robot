require "digest"
require "fileutils"
require "json"
require "time"
require "tmpdir"

class ClefEvaluation
  DATASETS = { "tuning" => "clef_evaluation_cases.json", "holdout" => "clef_holdout_cases.json" }.freeze
  BASELINE_QUESTION = {
    "type" => "choice",
    "instructions" => "イベント来訪者の現在の目的を分類してください。挨拶と案内要求が含まれる場合は案内要求を優先してください。目的を特定できない場合はunknownを選んでください。",
    "criteria" => {
      "greeting" => "案内要求を含まない挨拶",
      "reception" => "参加登録・受付手続きの場所を尋ねている",
      "hall" => "講演・発表を聞く場所を尋ねている",
      "unknown" => "目的が曖昧、対象外、または複数の要求を1つに絞れない"
    }
  }.freeze

  attr_reader :directory, :summary, :dataset, :request_count

  def initialize(variants: %w[baseline revised], cases: nil, dataset: "tuning", output_root: Rails.root.join("docs/evaluation"),
                 client_factory: ->(question) { ClefClient.new(question: question) })
    @questions = { "baseline" => BASELINE_QUESTION, "revised" => ClefClient.question }.slice(*variants)
    unless variants.any? && variants.uniq == variants && variants.all? { |variant| @questions.key?(variant) }
      raise ArgumentError, "分類基準はbaseline、revised、または両方を指定してください。"
    end
    raise ArgumentError, "評価データはtuningまたはholdoutを指定してください。" unless DATASETS.key?(dataset)
    @dataset = cases ? "custom" : dataset
    @cases = cases || JSON.parse(File.read(Rails.root.join("config", DATASETS.fetch(dataset)), encoding: "UTF-8"))
    unless @cases.is_a?(Array) && @cases.any? && @cases.all? { |item|
        item.is_a?(Hash) && item["id"].is_a?(String) && !item["id"].empty? &&
          ClefClient::INTENTS.include?(item["expected"]) && item["input"].is_a?(String) &&
          !item["input"].strip.empty? && item["input"].length <= ClefClient::MAX_INPUT_CHARACTERS
      } && @cases.map { |item| item["id"] }.uniq.size == @cases.size
      raise ArgumentError, "評価用入力が不正です。"
    end
    @client_factory = client_factory
    @request_count = @cases.size * @questions.size
    FileUtils.mkdir_p(output_root, mode: 0o700)
    @directory = Pathname.new(Dir.mktmpdir("clef-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-", output_root))
  end

  def run
    records = []
    write_json("metadata.json", {
      schema_version: 2, started_at: Time.now.utc.iso8601, model: ClefClient::MODEL, dataset: @dataset,
      cases_sha256: Digest::SHA256.hexdigest(JSON.generate(@cases)),
      confidence_threshold: ActionSelector::CONFIDENCE_THRESHOLD, cases: @cases,
      questions: @questions, question_sha256: @questions.transform_values { |question| Digest::SHA256.hexdigest(JSON.generate(question)) }
    })
    File.open(@directory.join("results.jsonl"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
      begin
        @questions.each do |variant, question|
          client = @client_factory.call(question)
          @cases.each do |item|
            record = evaluate(client, variant, item)
            output.puts(JSON.generate(record))
            output.flush
            records << record
            yield record if block_given?
            return records if record["error"]
          end
        end
      ensure
        @summary = summarize(records)
        write_json("summary.json", @summary)
      end
    end
    records
  end

  private

  def evaluate(client, variant, item)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    record = { "variant" => variant, "id" => item.fetch("id"), "input" => item.fetch("input"),
               "expected" => item.fetch("expected") }
    classification = client.classify(item.fetch("input"))
    selection = ActionSelector.call(classification)
    record.merge!("intent" => classification.intent, "confidence" => classification.confidence,
                  "probabilities" => classification.probabilities,
                  "selected_probability" => classification.probabilities.fetch(classification.intent),
                  "model" => classification.model, "input_tokens" => classification.input_tokens,
                  "intent_correct" => classification.intent == item.fetch("expected"),
                  "selection" => selection.to_h)
  rescue ClefClient::Error => error
    record.merge!("error" => { "code" => error.code, "http_status" => error.http_status },
                  "intent_correct" => false, "selection" => ActionSelector.failure.to_h)
  ensure
    record["elapsed_sec"] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(4)
  end

  def summarize(records)
    variants = @questions.keys.to_h do |variant|
      rows = records.select { |row| row["variant"] == variant }
      successful = rows.reject { |row| row["error"] }
      correct = successful.count { |row| row["intent_correct"] }
      complete = rows.size == @cases.size && successful.size == @cases.size
      correct_actions = successful.count { |row| row["selection"][:action] == ActionSelector::ACTIONS.fetch(row["expected"]).first }
      latencies = successful.map { |row| row.fetch("elapsed_sec") }.sort
      [ variant, {
        planned: @cases.size, attempted: rows.size, complete: complete,
        api_errors: rows.size - successful.size, correct: correct,
        accuracy: complete ? (correct.to_f / @cases.size).round(4) : nil,
        correct_actions: correct_actions,
        action_accuracy: complete ? (correct_actions.to_f / @cases.size).round(4) : nil,
        wrong_classifications: successful.count { |row| !row["intent_correct"] },
        holds: successful.count { |row| row["selection"][:action] == "hold" },
        unnecessary_holds: successful.count { |row| row["selection"][:action] == "hold" && row["expected"] != "unknown" },
        latency_sec: latencies.empty? ? nil : {
          min: latencies.first, max: latencies.last, mean: (latencies.sum / latencies.size).round(4),
          median: ((latencies[(latencies.size - 1) / 2] + latencies[latencies.size / 2]) / 2.0).round(4)
        },
        wrong_guidance: successful.count { |row|
          %w[reception hall].include?(row["selection"][:action]) && row["selection"][:action] != row["expected"]
        },
        unattempted_ids: @cases.map { |item| item["id"] } - rows.map { |row| row["id"] }
      } ]
    end
    { completed_at: Time.now.utc.iso8601, dataset: @dataset,
      complete: variants.values.all? { |variant| variant[:complete] }, variants: variants }
  end

  def write_json(name, data)
    File.open(@directory.join(name), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.puts(JSON.pretty_generate(data))
    end
  end
end
