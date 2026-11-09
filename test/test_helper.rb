# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"
require "webmock/minitest"

require "companyenrich"

WebMock.disable_net_connect!(allow_localhost: true)

module TestHelpers
  UUID = "00000000-0000-4000-8000-000000000001"

  attr_reader :requests, :delays

  def json_response(body, status: 200, headers: {})
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def problem(status, body = {}, headers = {})
    json_response({ status: status }.merge(body), status: status, headers: headers)
  end

  # Creates a client whose requests play back +responses+ in order. An entry that is an
  # exception, or an exception class, is raised instead of answered.
  def client_with(responses, **options)
    queue = responses.dup
    @requests = []
    stub_request(:any, /.*/).to_return do |request|
      @requests << request
      flunk "Unexpected extra request to #{request.uri}" if queue.empty?
      item = queue.shift
      raise item if item.is_a?(Exception) || item.is_a?(Class)

      item
    end
    build_client(**options)
  end

  def build_client(**options)
    client = CompanyEnrich::Client.new(api_key: "test-key", **options)
    @delays = []
    delays = @delays
    client.instance_variable_get(:@http).define_singleton_method(:pause) { |seconds| delays << seconds }
    client
  end

  def query_pairs(request)
    URI.decode_www_form(request.uri.query.to_s)
  end

  def body_of(request)
    JSON.parse(request.body)
  end

  def with_env(name, value)
    previous = ENV.fetch(name, nil)
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end
end

# A real TCP server, so tests can exercise Net::HTTP itself rather than a stub.
class FakeServer
  attr_reader :requests

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @requests = []
    @thread = Thread.new { serve(handler) }
  end

  def base_url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def serve(handler)
    loop do
      socket = @server.accept
      begin
        request = read_request(socket)
        @requests << request
        handler.call(socket, request)
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end
    end
  end

  def read_request(socket)
    request_line = socket.gets.to_s.strip
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    length = headers.fetch("content-length", "0").to_i
    { line: request_line, headers: headers, body: length.positive? ? socket.read(length) : "" }
  end
end
