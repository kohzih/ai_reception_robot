require "json"
require "net/http"
require "openssl"
require "timeout"

class ClefClient
  INTENTS = %w[greeting reception hall unknown].freeze
  MODEL = "clef".freeze
  MAX_INPUT_CHARACTERS = 200
  MAX_RESPONSE_BYTES = 65_536
  QUESTION_PATH = File.expand_path("../../config/intent_criteria.json", __dir__)
  Classification = Data.define(:intent, :confidence, :probabilities, :model, :input_tokens)

  class Error < StandardError
    attr_reader :code, :http_status

    def initialize(code, message, http_status: nil)
      @code, @http_status = code, http_status
      super(message)
    end
  end

  class RequestDeadline < Timeout::Error; end

  def self.question
    JSON.parse(File.read(QUESTION_PATH, encoding: "UTF-8"))
  end

  def self.valid_confidence?(value)
    (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value.between?(0, 1)
  end

  def initialize(account_id: ENV["CLOUDFLARE_ACCOUNT_ID"], api_token: ENV["CLOUDFLARE_API_TOKEN"],
                 question: self.class.question, open_timeout: 5, read_timeout: 20, write_timeout: 5,
                 total_timeout: 60, http_factory: ->(uri) { Net::HTTP.new(uri.host, uri.port) })
    unless account_id.is_a?(String) && account_id.strip.match?(/\A[a-zA-Z0-9_-]{1,128}\z/) &&
        api_token.is_a?(String) && api_token.match?(/\A[!-~]+\z/)
      raise Error.new("configuration_error", "Cloudflareの認証情報が未設定、または不正です。")
    end
    unless question.is_a?(Hash) && question["type"] == "choice" &&
        question["instructions"].is_a?(String) && !question["instructions"].strip.empty? &&
        question["criteria"].is_a?(Hash) && question["criteria"].keys.sort == INTENTS.sort &&
        question["criteria"].values.all? { |value| value.is_a?(String) && !value.strip.empty? }
      raise Error.new("configuration_error", "Clefの分類基準が不正です。")
    end
    [ open_timeout, read_timeout, write_timeout, total_timeout ].each do |seconds|
      unless (seconds.is_a?(Integer) || seconds.is_a?(Float)) && seconds.finite? && seconds.positive?
        raise Error.new("configuration_error", "Clefの通信期限が不正です。")
      end
    end
    @uri = URI("https://api.cloudflare.com/client/v4/accounts/#{account_id.strip}/ai/run/@cf/cloudflare/clef")
    @api_token = api_token
    @question = JSON.parse(JSON.generate(question))
    @open_timeout, @read_timeout, @write_timeout, @total_timeout = open_timeout, read_timeout, write_timeout, total_timeout
    @http_factory = http_factory
  end

  def inspect
    "#<#{self.class.name} [FILTERED]>"
  end

  def classify(input)
    unless input.is_a?(String) && input.valid_encoding? && !input.match?(/\A[[:space:]]*\z/) && input.length <= MAX_INPUT_CHARACTERS
      raise Error.new("invalid_input", "入力は1〜200文字の有効な文字列にしてください。")
    end
    Timeout.timeout(@total_timeout, RequestDeadline) do
      payload = JSON.generate(model: MODEL, state: input.encode("UTF-8"), questions: { intent: @question })
      parse_response(request(payload))
    end
  rescue RequestDeadline, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
    raise Error.new("timeout", "Clefへの通信が制限時間を超えました。"), cause: nil
  rescue SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    raise Error.new("connection_error", "Clefへ接続できませんでした。"), cause: nil
  rescue EncodingError
    raise Error.new("invalid_input", "入力の文字コードが不正です。"), cause: nil
  end

  private

  def request(payload)
    http = @http_factory.call(@uri)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.verify_hostname = true
    http.open_timeout = @open_timeout
    http.read_timeout = @read_timeout
    http.write_timeout = @write_timeout
    http.max_retries = 0
    request = Net::HTTP::Post.new(@uri.request_uri)
    request["Authorization"] = "Bearer #{@api_token}"
    request["Content-Type"] = "application/json; charset=utf-8"
    request["Accept"] = "application/json"
    request.body = payload
    body = +"".b
    http.start do |connection|
      connection.request(request) do |response|
        status = response.code.to_i
        unless status.between?(200, 299)
          code = case status
          when 401, 403 then "authentication_error"
          when 429 then "rate_limited"
          when 500..599 then "server_error"
          else "http_error"
          end
          raise Error.new(code, "Clef APIへのリクエストが失敗しました。", http_status: status)
        end
        response.read_body do |chunk|
          if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            raise Error.new("invalid_response", "Clefの応答サイズが上限を超えました。")
          end
          body << chunk
        end
      end
    end
    body.force_encoding("UTF-8")
  ensure
    request&.delete("Authorization")
  end

  def parse_response(body)
    response = JSON.parse(body)
    unless response.is_a?(Hash) && response["success"] == true && response["errors"] == []
      raise Error.new("api_error", "Clef APIが成功した分類結果を返しませんでした。")
    end
    result = response.fetch("result")
    answer = result.fetch("answers").fetch("intent")
    intent, confidence = answer.fetch("choice"), answer.fetch("confidence")
    probabilities = answer.fetch("probabilities")
    input_tokens = result.fetch("usage").fetch("input_tokens")
    unless result.fetch("model") == MODEL && answer.fetch("type") == "choice" &&
        INTENTS.include?(intent) && self.class.valid_confidence?(confidence) &&
        probabilities.is_a?(Hash) && probabilities.keys.sort == INTENTS.sort &&
        probabilities.values.all? { |value| self.class.valid_confidence?(value) } &&
        input_tokens.is_a?(Integer) && input_tokens >= 0
      raise Error.new("invalid_response", "Clefの分類結果が不正です。")
    end
    Classification.new(intent: intent.freeze, confidence: confidence, probabilities: probabilities.freeze,
                       model: MODEL, input_tokens: input_tokens)
  rescue JSON::ParserError, EncodingError, KeyError, TypeError, NoMethodError
    raise Error.new("invalid_response", "Clefの応答形式が不正です。"), cause: nil
  end
end
