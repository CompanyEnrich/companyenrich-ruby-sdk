# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"
require "zlib"

require_relative "errors"
require_relative "ndjson_decoder"
require_relative "version"

module CompanyEnrich
  # Sends requests, applies the retry policy, and maps failures to SDK errors.
  # @api private
  class HTTPClient
    DEFAULT_BASE_URL = "https://api.companyenrich.com"
    DEFAULT_TIMEOUT = 120
    DEFAULT_MAX_RETRIES = 2

    BASE_BACKOFF = 0.5
    MAX_BACKOFF = 8.0
    MAX_SERVER_REQUESTED_WAIT = 60.0
    RETRYABLE_STATUSES = [408, 500, 502, 503, 504].freeze
    TIMESPAN = /\A(\d+):(\d{2}):(\d{2}(?:\.\d+)?)\z/

    TIMEOUT_ERRORS = [Timeout::Error, Errno::ETIMEDOUT].freeze
    TRANSPORT_ERRORS = [
      *TIMEOUT_ERRORS, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError,
      Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error
    ].freeze

    def initialize(api_key:, base_url:, timeout:, max_retries:, default_headers:)
      @api_key = api_key || ENV.fetch("COMPANYENRICH_API_KEY", nil)
      if @api_key.nil? || @api_key.empty?
        raise Error, "Missing API key. Pass `api_key:` or set the COMPANYENRICH_API_KEY environment variable."
      end

      @base_uri = URI.parse(base_url.sub(%r{/+\z}, ""))
      @timeout = timeout
      @max_retries = max_retries
      @default_headers = default_headers
    end

    # Keeps the API key out of logs and error messages.
    def inspect
      "#<#{self.class} base_url=#{@base_uri}>"
    end

    # Sends a request and parses the JSON response.
    def request(method, path, query: nil, body: nil, retry_safe: nil, options: nil)
      execute(method, path, query, body, retry_safe, options, accept: "application/json") do |response|
        parse_json(response.read_body, response.code.to_i)
      end
    end

    # Sends a GET request and yields the response body as it arrives.
    def stream_chunks(path, query: nil, options: nil, &block)
      execute("GET", path, query, nil, nil, options, accept: "*/*", stream: true) do |response|
        read_chunks(response, &block)
      end
    end

    # Sends a GET request to an NDJSON endpoint and yields one parsed record per line.
    def stream_ndjson(path, query: nil, options: nil)
      decoder = NdjsonDecoder.new
      stream_chunks(path, query: query, options: options) do |chunk|
        decoder.feed(chunk).each { |record| yield record }
      end
      decoder.flush.each { |record| yield record }
    end

    def pause(seconds)
      sleep(seconds)
    end

    private

    def execute(method, path, query, body, retry_safe, options, accept:, stream: false)
      options ||= {}
      max_retries = options.fetch(:max_retries, @max_retries)
      safe = retry_safe.nil? ? method == "GET" : retry_safe
      attempt = 0
      streaming = false

      begin
        connect(options.fetch(:timeout, @timeout)) do |http|
          http.request(build_request(method, path, query, body, options, accept)) do |response|
            raise_for_status(response)
            # Once records have been handed over, repeating the download would duplicate them.
            streaming = stream
            return yield(response)
          end
        end
      rescue APIError, *TRANSPORT_ERRORS => e
        raise if streaming

        failure = normalize_failure(e)
        delay = retry_delay(failure, attempt, safe)
        raise failure if delay.nil? || attempt >= max_retries

        pause(delay)
        attempt += 1
        retry
      end
    end

    def connect(timeout, &)
      Net::HTTP.start(
        @base_uri.host, @base_uri.port,
        use_ssl: @base_uri.scheme == "https",
        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout,
        # Retries follow this SDK's policy only, so a request is never repeated behind its back.
        max_retries: 0,
        # By default Net::HTTP accepts a truncated body as complete, which would silently lose records.
        ignore_eof: false,
        &
      )
    end

    def build_request(method, path, query, body, options, accept)
      request_class = method == "POST" ? Net::HTTP::Post : Net::HTTP::Get
      request = request_class.new(request_target(path, query), request_headers(accept, body, options))
      if body
        request.body = JSON.generate(body)
      elsif method == "POST"
        request["Content-Length"] = "0"
        # Net::HTTP would otherwise label an empty POST as a submitted form.
        request["Content-Type"] = "application/json"
      end
      request
    end

    def request_target(path, query)
      target = "#{@base_uri.path}#{path}"
      pairs = (query || {}).flat_map do |key, value|
        next [] if value.nil?

        Array(value).map { |item| [key.to_s, item.to_s] }
      end
      pairs.empty? ? target : "#{target}?#{URI.encode_www_form(pairs)}"
    end

    def request_headers(accept, body, options)
      headers = {
        "accept" => accept,
        "authorization" => "Bearer #{@api_key}",
        "user-agent" => "companyenrich-ruby/#{VERSION}"
      }
      headers["content-type"] = "application/json" if body
      [@default_headers, options[:headers]].compact.each do |extra|
        extra.each { |name, value| headers[name.to_s.downcase] = value }
      end
      headers
    end

    def raise_for_status(response)
      status = response.code.to_i
      return if status.between?(200, 299)

      raise CompanyEnrich.api_error(
        status: status, headers: response_headers(response), body: parse_error_body(response.read_body)
      )
    end

    def response_headers(response)
      response.to_hash.transform_values { |values| values.join(", ") }
    end

    # Hands each chunk to the caller. Network failures become SDK errors, while exceptions
    # raised by the caller's own block pass through unchanged.
    def read_chunks(response)
      caller_failure = nil
      response.read_body do |chunk|
        yield chunk
      rescue Exception => e # rubocop:disable Lint/RescueException
        caller_failure = e
        raise
      end
    rescue *TRANSPORT_ERRORS => e
      raise if e.equal?(caller_failure)
      raise APITimeoutError, "Download timed out: #{e.message}" if timeout_error?(e)

      raise APIConnectionError, "Download was interrupted: #{e.message}"
    end

    def normalize_failure(error)
      return error if error.is_a?(APIError)

      if timeout_error?(error)
        APITimeoutError.new("Request timed out: #{error.message}")
      else
        APIConnectionError.new("Could not reach the CompanyEnrich API: #{error.message}")
      end
    end

    def timeout_error?(error)
      TIMEOUT_ERRORS.any? { |type| error.is_a?(type) }
    end

    # @return [Numeric, nil] how long to wait before retrying, or nil if the request must not be retried
    def retry_delay(failure, attempt, safe)
      return safe ? backoff(attempt) : nil unless failure.is_a?(APIError)

      status = failure.status
      # A 429 is rejected before any work happens, so it is safe to repeat for every request.
      return nil unless status == 429 || (safe && RETRYABLE_STATUSES.include?(status))

      requested = parse_retry_after(failure.headers["retry-after"])
      requested ||= parse_timespan(failure.headers["x-ratelimit-window"]) if status == 429
      return backoff(attempt) if requested.nil?

      requested <= MAX_SERVER_REQUESTED_WAIT ? requested : nil
    end

    def backoff(attempt)
      ceiling = [MAX_BACKOFF, BASE_BACKOFF * (2**attempt)].min
      ceiling * (0.75 + (rand * 0.25))
    end

    def parse_retry_after(value)
      return nil if value.nil? || value.empty?

      [Float(value), 0.0].max
    rescue ArgumentError
      begin
        [Time.httpdate(value) - Time.now, 0.0].max
      rescue ArgumentError
        nil
      end
    end

    # Parses a .NET TimeSpan such as 00:00:35.7551671 into seconds.
    def parse_timespan(value)
      match = TIMESPAN.match(value.to_s)
      return nil unless match

      (match[1].to_i * 3600) + (match[2].to_i * 60) + match[3].to_f
    end

    def parse_json(content, status)
      return nil if content.nil? || content.empty?

      JSON.parse(content)
    rescue JSON::ParserError
      raise Error, "The API returned an invalid JSON response (status #{status})"
    end

    def parse_error_body(content)
      text = content.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end
end
