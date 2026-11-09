# frozen_string_literal: true

require "test_helper"

# Exercises real Net::HTTP behavior over a socket, which stubbed requests cannot.
class RealSocketTest < Minitest::Test
  include TestHelpers
  include CompanyEnrich

  # WebMock buffers responses even when it allows a connection, so it has to be switched off here.
  def setup
    WebMock.disable!
  end

  def teardown
    @server&.close
    WebMock.enable!
  end

  def serve(&)
    @server = FakeServer.new(&)
    build_client(base_url: @server.base_url, timeout: 2)
  end

  def respond(socket, status, body, headers = {})
    lines = ["HTTP/1.1 #{status} X", "Content-Length: #{body.bytesize}", "Connection: close"]
    lines += headers.map { |name, value| "#{name}: #{value}" }
    socket.write("#{lines.join("\r\n")}\r\n\r\n#{body}")
  end

  def start_stream(socket, length)
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{length}\r\nConnection: close\r\n\r\n")
  end

  def test_sends_a_complete_json_request
    client = serve { |socket, _| respond(socket, 200, '{"items":[]}') }
    assert_equal({ "items" => [] }, client.companies.search(page_size: 3, expand: ["keywords"]))
    request = @server.requests.first
    assert_equal "POST /v2/companies/search HTTP/1.1", request[:line]
    assert_equal "Bearer test-key", request[:headers]["authorization"]
    assert_equal "application/json", request[:headers]["content-type"]
    assert_equal({ "pageSize" => 3, "expand" => ["keywords"] }, JSON.parse(request[:body]))
  end

  def test_repeats_list_params_and_omits_unset_ones
    client = serve { |socket, _| respond(socket, 200, "{}") }
    client.companies.enrich("stripe.com", expand: %w[financial workforce], wait_for_enrichment: false)
    assert_equal(
      "GET /v2/companies/enrich?domain=stripe.com&expand=financial&expand=workforce&waitForEnrichment=false HTTP/1.1",
      @server.requests.first[:line]
    )
  end

  def test_a_post_without_a_body_declares_zero_length
    client = serve { |socket, _| respond(socket, 200, "{}") }
    client.batches.cancel("id")
    request = @server.requests.first
    assert_equal "0", request[:headers]["content-length"]
    assert_equal "application/json", request[:headers]["content-type"]
    assert_equal "", request[:body]
  end

  def test_a_truncated_json_response_is_a_connection_error
    client = serve do |socket, _|
      start_stream(socket, 1000)
      socket.write('{"items":')
    end
    assert_raises(APIConnectionError) { client.companies.search }
    assert_equal 1, @server.requests.size
  end

  def test_does_not_repeat_a_paid_post_when_the_connection_drops
    client = serve { |socket, _| socket.close }
    assert_raises(APIConnectionError) { client.companies.search }
    assert_equal 1, @server.requests.size
  end

  def test_retries_a_get_after_a_real_server_error
    attempts = 0
    client = serve do |socket, _|
      attempts += 1
      attempts == 1 ? respond(socket, 503, "{}") : respond(socket, 200, '{"userId":"u"}')
    end
    assert_equal "u", client.me["userId"]
    assert_equal 2, @server.requests.size
  end

  def test_reports_a_read_timeout
    client = serve { |_socket, _| sleep 1 }
    client.instance_variable_get(:@http).instance_variable_set(:@timeout, 0.05)
    error = assert_raises(APITimeoutError) { client.me(options: { max_retries: 0 }) }
    assert_kind_of Timeout::Error, error.cause
  end

  def test_reports_a_refused_connection
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    client = build_client(base_url: "http://127.0.0.1:#{port}", max_retries: 0)
    assert_raises(APIConnectionError) { client.me }
  end

  def test_streams_records_across_packets
    payload = "{\"domain\":\"café.com\"}\n{\"domain\":\"b.com\"}\n".b
    split = payload.index("\xC3".b) + 1
    client = serve do |socket, _|
      start_stream(socket, payload.bytesize)
      socket.write(payload[0...split])
      socket.flush
      sleep 0.02
      socket.write(payload[split..])
    end
    assert_equal(["café.com", "b.com"], client.batches.raw_results(UUID).map { |record| record["domain"] })
  end

  def test_delivers_records_then_raises_without_retrying_when_a_download_drops
    client = serve do |socket, _|
      start_stream(socket, 1000)
      socket.write("{\"index\":0}\n")
      socket.flush
      sleep 0.02
    end
    seen = []
    assert_raises(APIConnectionError) { client.batches.raw_results(UUID) { |record| seen << record["index"] } }
    assert_equal [0], seen
    assert_equal 1, @server.requests.size
  end

  def test_raises_a_timeout_when_a_download_stalls
    client = serve do |socket, _|
      start_stream(socket, 1000)
      socket.write("{\"index\":0}\n")
      socket.flush
      sleep 1
    end
    client.instance_variable_get(:@http).instance_variable_set(:@timeout, 0.05)
    assert_raises(APITimeoutError) { client.batches.raw_results(UUID) { |_record| nil } }
    assert_equal 1, @server.requests.size
  end

  def test_lets_exceptions_from_the_callers_block_pass_through_unchanged
    client = serve do |socket, _|
      start_stream(socket, 12)
      socket.write("{\"index\":0}\n")
    end
    assert_raises(Errno::ENOSPC) { client.batches.raw_results(UUID) { |_record| raise Errno::ENOSPC } }
    assert_equal 1, @server.requests.size
  end

  def test_stops_a_download_when_the_caller_stops_early
    client = serve do |socket, _|
      start_stream(socket, 24)
      socket.write("{\"index\":0}\n{\"index\":1}\n")
    end
    first = client.batches.raw_results(UUID).first
    assert_equal({ "index" => 0 }, first)
    assert_equal 1, @server.requests.size
  end
end
