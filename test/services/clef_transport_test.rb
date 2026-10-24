require "test_helper"
require "socket"
require_relative "../support/clef_test_data"

class ClefTransportTest < ActiveSupport::TestCase
  def with_tls_server(&handler)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=api.cloudflare.com")
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    extension = OpenSSL::X509::ExtensionFactory.new
    extension.subject_certificate = extension.issuer_certificate = certificate
    certificate.add_extension(extension.create_extension("basicConstraints", "CA:TRUE", true))
    certificate.add_extension(extension.create_extension("subjectAltName", "DNS:api.cloudflare.com"))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = certificate, key
    tcp = TCPServer.new("127.0.0.1", 0)
    server = OpenSSL::SSL::SSLServer.new(tcp, context)
    thread = Thread.new do
      socket = server.accept
      headers = +""
      headers << socket.gets until headers.end_with?("\r\n\r\n")
      socket.read(headers[/content-length: (\d+)/i, 1].to_i)
      handler.call(socket)
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      # The client closes the connection when its deadline expires.
    ensure
      socket&.close
    end
    store = OpenSSL::X509::Store.new
    store.add_cert(certificate)
    factory = ->(uri) {
      Net::HTTP.new(uri.host, tcp.addr[1], nil).tap do |http|
        http.ipaddr = "127.0.0.1"
        http.cert_store = store
      end
    }
    yield_client(factory)
  ensure
    tcp&.close
    thread&.kill if thread&.alive?
    thread&.join
  end

  test "real TLS validates the peer and transfers Japanese text on a loopback connection" do
    response = JSON.generate(ClefTestData.response)
    @exercise = ->(factory) {
      client = ClefClient.new(account_id: "a" * 32, api_token: "local-test-token", http_factory: factory)
      assert_equal "hall", client.classify("こんにちは、講演会場はどこですか？").intent
    }
    with_tls_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
    end
  end

  test "slow response chunks cannot bypass the overall deadline" do
    @exercise = ->(factory) {
      client = ClefClient.new(account_id: "a" * 32, api_token: "local-test-token", http_factory: factory,
                              open_timeout: 2, read_timeout: 1, total_timeout: 0.5)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(ClefClient::Error) { client.classify("こんにちは") }
      assert_equal "timeout", error.code
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
    }
    with_tls_server do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
      50.times do
        socket.write(" ")
        sleep 0.05
      end
    end
  end

  private

  def yield_client(factory)
    @exercise.call(factory)
  end
end
