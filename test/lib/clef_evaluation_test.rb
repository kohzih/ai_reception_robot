require "test_helper"
require_relative "../support/clef_test_data"

class ClefEvaluationTest < ActiveSupport::TestCase
  def cases
    [ { "id" => "hello", "input" => "こんにちは。", "expected" => "greeting" },
      { "id" => "outside", "input" => "トイレはどこですか？", "expected" => "unknown" } ]
  end

  def client(&block)
    Object.new.tap { |instance| instance.define_singleton_method(:classify, &block) }
  end

  test "compares both criteria without deleting misclassifications or recording credentials" do
    Dir.mktmpdir do |root|
      calls = []
      evaluation = ClefEvaluation.new(cases: cases, output_root: root, client_factory: ->(_question) {
        client do |input|
          calls << input
          input == "こんにちは。" ? ClefTestData.classification(intent: "greeting") : ClefTestData.classification(confidence: 0.2130)
        end
      })
      records = evaluation.run
      assert_equal cases.map { |item| item["input"] } * 2, calls
      assert_equal 4, records.size
      assert evaluation.summary[:complete]
      evaluation.summary[:variants].each_value do |variant|
        assert_equal 2, variant[:attempted]
        assert_equal 1, variant[:correct]
        assert_equal 0.5, variant[:accuracy]
        assert_equal 1, variant[:wrong_classifications]
        assert_equal 1, variant[:holds]
        assert_equal 0, variant[:wrong_guidance]
      end
      metadata = JSON.parse(evaluation.directory.join("metadata.json").read)
      assert_equal cases, metadata["cases"]
      refute_equal metadata.dig("questions", "baseline"), metadata.dig("questions", "revised")
      assert_equal %w[baseline revised], metadata["question_sha256"].keys
      rows = evaluation.directory.join("results.jsonl").readlines.map { |line| JSON.parse(line) }
      wrong = rows.select { |row| row["id"] == "outside" }
      assert_equal 2, wrong.size
      wrong.each do |row|
        refute row["intent_correct"]
        assert_equal "hall", row["intent"]
        assert_equal "hold", row.dig("selection", "action")
        assert_equal "scripts/robot/hold.py", row.dig("selection", "script")
        assert row.key?("elapsed_sec")
      end
      assert_equal 0o700, evaluation.directory.stat.mode & 0o777
      evaluation.directory.children.each do |path|
        assert_equal 0o600, path.stat.mode & 0o777
        refute_includes path.read, "Authorization"
        refute_includes path.read, "CLOUDFLARE_API_TOKEN"
      end
    end
  end

  test "API error preserves previous rows and every planned input while stopping further calls" do
    Dir.mktmpdir do |root|
      calls = 0
      evaluation = ClefEvaluation.new(cases: cases, output_root: root, client_factory: ->(_question) {
        client do |_input|
          calls += 1
          raise ClefClient::Error.new("rate_limited", "test-only-token", http_status: 429) if calls == 2
          ClefTestData.classification(intent: "greeting")
        end
      })
      rows = evaluation.run
      assert_equal 2, calls
      assert_equal 2, rows.size
      assert_nil rows.last.dig("selection", :action)
      assert_nil rows.last.dig("selection", :script)
      refute evaluation.summary[:complete]
      assert_nil evaluation.summary.dig(:variants, "baseline", :accuracy)
      assert_equal 1, evaluation.summary.dig(:variants, "baseline", :api_errors)
      assert_equal cases.map { |item| item["id"] }, evaluation.summary.dig(:variants, "revised", :unattempted_ids)
      evaluation.directory.children.each { |path| refute_includes path.read, "test-only-token" }
      assert_equal cases, JSON.parse(evaluation.directory.join("metadata.json").read)["cases"]
    end
  end

  test "interruption saves a partial summary and retains completed responses" do
    Dir.mktmpdir do |root|
      calls = 0
      evaluation = ClefEvaluation.new(cases: cases, output_root: root, client_factory: ->(_question) {
        client do |_input|
          calls += 1
          raise Interrupt if calls == 2
          ClefTestData.classification(intent: "greeting")
        end
      })
      assert_raises(Interrupt) { evaluation.run }
      refute evaluation.summary[:complete]
      assert_equal 1, evaluation.directory.join("results.jsonl").readlines.size
      assert_equal false, JSON.parse(evaluation.directory.join("summary.json").read)["complete"]
    end
  end

  test "evaluation runs use separate folders and include the full 15 case manifest" do
    Dir.mktmpdir do |root|
      first = ClefEvaluation.new(output_root: root)
      second = ClefEvaluation.new(output_root: root)
      refute_equal first.directory, second.directory
      manifest = JSON.parse(Rails.root.join("config/clef_evaluation_cases.json").read)
      assert_equal 15, manifest.size
      assert_equal 15, manifest.map { |item| item["id"] }.uniq.size
      assert_equal 3, manifest.count { |item| item["id"].start_with?("outside_", "negation_") }
    end
  end
end
