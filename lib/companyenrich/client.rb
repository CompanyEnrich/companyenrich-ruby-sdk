# frozen_string_literal: true

require_relative "http_client"
require_relative "resources/batches"
require_relative "resources/companies"
require_relative "resources/geo"
require_relative "resources/people"
require_relative "resources/reference"

module CompanyEnrich
  # Client for the CompanyEnrich API.
  class Client
    attr_reader :companies, :people, :batches, :geo, :industries, :keywords, :technologies, :positions

    # @param api_key [String, nil] defaults to the +COMPANYENRICH_API_KEY+ environment variable
    # @param base_url [String] API origin, for proxies
    # @param timeout [Numeric, nil] timeout in seconds for each attempt. +nil+ disables it.
    # @param max_retries [Integer] how many times to retry a failed request
    # @param default_headers [Hash, nil] headers sent with every request
    def initialize(api_key: nil, base_url: HTTPClient::DEFAULT_BASE_URL, timeout: HTTPClient::DEFAULT_TIMEOUT,
                   max_retries: HTTPClient::DEFAULT_MAX_RETRIES, default_headers: nil)
      @http = HTTPClient.new(
        api_key: api_key, base_url: base_url, timeout: timeout,
        max_retries: max_retries, default_headers: default_headers
      )
      @companies = Resources::Companies.new(@http)
      @people = Resources::People.new(@http)
      @batches = Resources::Batches.new(@http)
      @geo = Resources::Geo.new(@http)
      @industries = Resources::Industries.new(@http)
      @keywords = Resources::Autocomplete.new(@http, "/v2/keywords/autocomplete")
      @technologies = Resources::Autocomplete.new(@http, "/v2/technologies/autocomplete")
      @positions = Resources::Autocomplete.new(@http, "/v2/positions/autocomplete")
    end

    # Returns the authenticated user, including credit balance and plan capabilities. Free.
    def me(options: nil)
      @http.request("GET", "/v2/me", options: options)
    end
  end
end
