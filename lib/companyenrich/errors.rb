# frozen_string_literal: true

module CompanyEnrich
  # Base class for every error raised by this SDK.
  class Error < StandardError; end

  # The request never produced a response, for example because of a DNS or socket failure.
  class APIConnectionError < Error; end

  # The request, or a +batches.wait_for_completion+ call, ran out of time.
  class APITimeoutError < Error; end

  # The API responded with a non-2xx status.
  class APIError < Error
    # @return [Integer] the HTTP status
    attr_reader :status
    # @return [Hash{String => String}] response headers, with lowercase names
    attr_reader :headers
    # @return [Object] the parsed response body, or the raw text if it was not JSON
    attr_reader :body
    # @return [Hash{String => Array<String>}, nil] field-level validation messages
    attr_reader :errors
    # @return [String, nil] value of the +x-trace-id+ header. Include it in support requests.
    attr_reader :trace_id
    attr_reader :type, :title, :detail, :instance

    def initialize(status:, headers:, body:)
      problem = body.is_a?(Hash) ? body : {}
      super(self.class.format_message(status, problem))
      @status = status
      @headers = headers
      @body = body
      @type = problem["type"]
      @title = problem["title"]
      @detail = problem["detail"]
      @instance = problem["instance"]
      @errors = problem["errors"]
      @trace_id = headers["x-trace-id"]
    end

    def self.format_message(status, problem)
      summary = [problem["title"], problem["detail"]].compact.reject(&:empty?).join(": ")
      fields = (problem["errors"] || {}).map { |field, messages| "#{field}: #{messages.join(", ")}" }.join("; ")
      [status.to_s, summary, fields.empty? ? nil : "(#{fields})"].compact.reject(&:empty?).join(" ")
    end
  end

  # +400+: the request was malformed.
  class BadRequestError < APIError; end

  # +401+: the API key is missing or invalid.
  class AuthenticationError < APIError; end

  # +402+: the account is out of credits or its plan does not include this request.
  class PaymentRequiredError < APIError; end

  # +403+: the API key may not perform this request.
  class PermissionDeniedError < APIError; end

  # +404+: the company, person, or batch does not exist.
  class NotFoundError < APIError; end

  # +422+: the request failed validation. See {APIError#errors}.
  class ValidationError < APIError; end

  # +429+: a rate limit was exceeded and automatic retries did not resolve it.
  class RateLimitError < APIError; end

  # +5xx+: the API failed to process the request.
  class ServerError < APIError; end

  ERRORS_BY_STATUS = {
    400 => BadRequestError,
    401 => AuthenticationError,
    402 => PaymentRequiredError,
    403 => PermissionDeniedError,
    404 => NotFoundError,
    422 => ValidationError,
    429 => RateLimitError
  }.freeze
  private_constant :ERRORS_BY_STATUS

  # @api private
  def self.api_error(status:, headers:, body:)
    fallback = status >= 500 ? ServerError : APIError
    ERRORS_BY_STATUS.fetch(status, fallback).new(status: status, headers: headers, body: body)
  end
end
