require "test_helper"
require_relative "../support/clef_test_data"

class ClefClientTest < ActiveSupport::TestCase
  class FakeHTTP
    attr_accessor :use_ssl, :verify_mode, :verify_hostname, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests, :closed

    def initialize(body:, status: 200, error: nil, delay: 0)
      @body, @status, @error, @delay = body, status, error, delay
      @requests = []
    end

    def start
      begin
        sleep @delay if @delay.positive?
        raise @error if @error
        yield self
      ensure
        @closed = true
      end
    end

    def request(request)
      @requests << { path: request.path, headers: request.to_hash, body: request.body }
      response = Struct.new(:code, :chunks) do
        def read_body
          chunks.each { |chunk| yield chunk }
        end
      end.new(@status.to_s, [ @body ])
      yield response
    end
  end

  def build_client(payload: ClefTestData.response, status: 200, error: nil, delay: 0, **options)
    http = FakeHTTP.new(body: payload.is_a?(String) ? payload : JSON.generate(payload), status: status, error: error, delay: delay)
    client = ClefClient.new(account_id: "a" * 32, api_token: "test-only-token", http_factory: ->(_uri) { http }, **options)
    [ client, http ]
  end

  test "sends Japanese UTF-8 with the exact Clef schema and verified HTTPS" do
    client, http = build_client
    result = client.classify("こんにちは、講演会場はどこですか？")
    request = http.requests.sole
    payload = JSON.parse(request[:body])
    assert_equal "こんにちは、講演会場はどこですか？", payload["state"]
    assert_equal "clef", payload["model"]
    assert_equal ClefClient.question, payload.dig("questions", "intent")
    assert_equal "/client/v4/accounts/#{'a' * 32}/ai/run/@cf/cloudflare/clef", request[:path]
    assert_equal [ "Bearer test-only-token" ], request[:headers]["authorization"]
    assert_equal [ "application/json; charset=utf-8" ], request[:headers]["content-type"]
    assert http.use_ssl
    assert http.verify_hostname
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal [ 5, 20, 5, 0 ], [ http.open_timeout, http.read_timeout, http.write_timeout, http.max_retries ]
    assert http.closed
    assert_equal "hall", result.intent
    assert_equal 0.8546, result.confidence
    assert_equal 232, result.input_tokens
    assert_equal 0.94, result.probabilities["hall"]
    assert result.frozen?
    assert result.probabilities.frozen?
    refute_includes client.inspect, "test-only-token"
    refute_includes client.inspect, "a" * 32
  end

  test "rejects invalid input without opening a connection" do
    client, http = build_client
    [ nil, true, "", "　 \n", "あ" * 201, "\xff".b.force_encoding("UTF-8") ].each do |input|
      error = assert_raises(ClefClient::Error) { client.classify(input) }
      assert_equal "invalid_input", error.code
    end
    assert_empty http.requests
    refute http.closed
    assert_equal "hall", client.classify("あ" * 200).intent
  end

  test "rejects missing credentials malformed headers and unsupported questions" do
    [ { account_id: nil }, { account_id: "../other" }, { api_token: "" }, { api_token: "token\nInjected: value" },
      { total_timeout: 0 }, { read_timeout: Float::INFINITY }, { question: {} } ].each do |options|
      error = assert_raises(ClefClient::Error) do
        ClefClient.new(**{ account_id: "a" * 32, api_token: "test-only-token" }.merge(options))
      end
      assert_equal "configuration_error", error.code
    end
  end

  test "HTTP errors never become classifications and are not retried or redirected" do
    { 301 => "http_error", 400 => "http_error", 401 => "authentication_error", 403 => "authentication_error",
      429 => "rate_limited", 500 => "server_error", 503 => "server_error" }.each do |status, expected|
      client, http = build_client(status: status, payload: "test-only-token")
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal expected, error.code
      assert_equal status, error.http_status
      assert_equal 1, http.requests.size
      assert http.closed
      refute_includes error.message, "test-only-token"
    end
  end

  test "API failure flags and errors are rejected even with valid answers" do
    [ { "success" => false }, { "success" => "true" }, { "errors" => nil },
      { "errors" => [ { "message" => "test-only-token" } ] } ].each do |changes|
      client, = build_client(payload: ClefTestData.response.merge(changes))
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal "api_error", error.code
      refute_includes error.message, "test-only-token"
    end
  end

  test "malformed JSON and missing result structures are rejected" do
    payloads = [ "{broken", "null", "[]", { "success" => true, "errors" => [] },
                 ClefTestData.response.merge("result" => nil), ClefTestData.response.merge("result" => []) ]
    payloads.each do |payload|
      client, = build_client(payload: payload)
      assert_raises(ClefClient::Error) { client.classify("こんにちは") }
    end
  end

  test "untrusted answer types intents confidences and probabilities are rejected" do
    changes = [ [ "type", "score" ], [ "choice", "parking" ], [ "choice", nil ],
                [ "confidence", nil ], [ "confidence", "0.8" ], [ "confidence", true ],
                [ "confidence", -0.01 ], [ "confidence", 1.01 ], [ "probabilities", {} ],
                [ "probabilities", { "hall" => 1.0 } ],
                [ "probabilities", ClefClient::INTENTS.to_h { |intent| [ intent, -0.1 ] } ] ]
    changes.each do |key, value|
      payload = ClefTestData.response
      payload["result"]["answers"]["intent"][key] = value
      client, = build_client(payload: payload)
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal "invalid_response", error.code
    end
    [ "type", "choice", "confidence", "probabilities" ].each do |key|
      payload = ClefTestData.response
      payload["result"]["answers"]["intent"].delete(key)
      client, = build_client(payload: payload)
      assert_raises(ClefClient::Error) { client.classify("こんにちは") }
    end
  end

  test "unexpected model and malformed usage are rejected" do
    [ { "model" => "another-model" }, { "usage" => nil }, { "usage" => {} },
      { "usage" => { "input_tokens" => -1 } }, { "usage" => { "input_tokens" => "232" } } ].each do |changes|
      payload = ClefTestData.response
      payload["result"].merge!(changes)
      client, = build_client(payload: payload)
      assert_raises(ClefClient::Error) { client.classify("こんにちは") }
    end
  end

  test "oversized responses are rejected before parsing" do
    client, http = build_client(payload: "x" * (ClefClient::MAX_RESPONSE_BYTES + 1))
    error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
    assert_equal "invalid_response", error.code
    assert http.closed
  end

  test "connection failures and each transport timeout are sanitized" do
    [ SocketError.new("test-only-token"), Errno::ECONNREFUSED.new, EOFError.new,
      OpenSSL::SSL::SSLError.new("test-only-token"), Net::HTTPBadResponse.new("broken") ].each do |failure|
      client, http = build_client(error: failure)
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal "connection_error", error.code
      assert http.closed
      assert_nil error.cause
      refute_includes error.message, "test-only-token"
    end
    [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout ].each do |failure|
      client, = build_client(error: failure.new)
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal "timeout", error.code
    end
  end

  test "overall deadline interrupts a blocked transport and closes it" do
    client, http = build_client(delay: 2.0, total_timeout: 0.05)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
    assert_equal "timeout", error.code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    assert http.closed
  end
end
