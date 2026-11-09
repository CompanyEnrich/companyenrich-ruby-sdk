# frozen_string_literal: true

require "test_helper"

class HTTPClientTest < Minitest::Test
  include TestHelpers
  include CompanyEnrich

  def test_sends_the_bearer_token_to_the_production_api
    client_with([json_response({ userId: "u" })]).me
    request = requests.first
    assert_equal "https://api.companyenrich.com:443/v2/me", request.uri.to_s
    assert_equal :get, request.method
    assert_equal "Bearer test-key", request.headers["Authorization"]
    assert_match %r{\Acompanyenrich-ruby/}, request.headers["User-Agent"]
    assert_nil request.headers["Content-Type"]
  end

  def test_reads_the_api_key_from_the_environment
    stub_request(:get, %r{/v2/me}).to_return(json_response({}))
    with_env("COMPANYENRICH_API_KEY", "env-key") { Client.new.me }
    assert_requested(:get, %r{/v2/me}, headers: { "Authorization" => "Bearer env-key" })
  end

  def test_requires_an_api_key
    [nil, ""].each do |value|
      with_env("COMPANYENRICH_API_KEY", value) do
        error = assert_raises(Error) { Client.new }
        assert_match(/Missing API key/, error.message)
      end
    end
  end

  def test_keeps_the_api_key_out_of_inspect
    client = Client.new(api_key: "super-secret")
    refute_includes client.inspect, "super-secret"
  end

  def test_sends_an_empty_object_for_an_unfiltered_search
    client_with([json_response({ items: [] })]).companies.search
    request = requests.first
    assert_equal :post, request.method
    assert_equal "{}", request.body
    assert_equal "application/json", request.headers["Content-Type"]
  end

  def test_maps_snake_case_arguments_to_api_field_names
    client_with([json_response({ items: [] })]).companies.search(page_size: 5, cursor: "c", filter: { country: "US" })
    assert_equal({ "pageSize" => 5, "cursor" => "c", "filter" => { "country" => "US" } }, body_of(requests.first))
  end

  def test_encodes_path_params_and_keeps_large_person_ids_exact
    large = 9_007_199_254_740_993
    client = client_with([json_response({}), json_response({ id: large })])
    client.geo.country("a/b")
    person = client.people.get(large)
    assert_equal "/v2/geo/countries/a%2Fb", requests[0].uri.path
    assert_equal "/v2/people/#{large}", requests[1].uri.path
    assert_equal large, person["id"]
  end

  def test_merges_headers_and_keeps_a_base_url_path
    client = client_with(
      [json_response({})],
      base_url: "https://proxy.example.com/ce/",
      default_headers: { "x-team" => "growth", "X-Override" => "default" }
    )
    client.me(options: { headers: { "x-override" => "request" } })
    request = requests.first
    assert_equal "/ce/v2/me", request.uri.path
    assert_equal "proxy.example.com", request.uri.host
    assert_equal "growth", request.headers["X-Team"]
    assert_equal "request", request.headers["X-Override"]
  end

  {
    400 => BadRequestError, 401 => AuthenticationError, 402 => PaymentRequiredError,
    403 => PermissionDeniedError, 404 => NotFoundError, 422 => ValidationError,
    429 => RateLimitError, 500 => ServerError, 503 => ServerError, 413 => APIError
  }.each do |status, error_class|
    define_method(:"test_maps_#{status}_to_#{error_class.name.split("::").last}") do
      client = client_with([problem(status)], max_retries: 0)
      error = assert_raises(APIError) { client.me }
      assert_instance_of error_class, error
      assert_kind_of Error, error
      assert_equal status, error.status
    end
  end

  def test_exposes_problem_details_and_the_trace_id
    body = { title: "Unauthorized", detail: "Invalid token.", type: "about:blank" }
    client = client_with([problem(401, body, { "x-trace-id" => "trace-123" })])
    error = assert_raises(AuthenticationError) { client.me }
    assert_equal "401 Unauthorized: Invalid token.", error.message
    assert_equal "Unauthorized", error.title
    assert_equal "Invalid token.", error.detail
    assert_equal "about:blank", error.type
    assert_equal "trace-123", error.trace_id
  end

  def test_includes_field_level_validation_messages
    errors = { "domain" => ["Required", "Too short"] }
    client = client_with([problem(422, { title: "Validation", errors: errors })])
    error = assert_raises(ValidationError) { client.me }
    assert_equal errors, error.errors
    assert_includes error.message, "domain: Required, Too short"
  end

  def test_keeps_non_json_error_bodies
    client = client_with([{ status: 502, body: "<html>Bad</html>" }], max_retries: 0)
    error = assert_raises(ServerError) { client.me }
    assert_equal "<html>Bad</html>", error.body
    assert_equal "502", error.message
  end

  def test_reports_a_malformed_success_body_without_retrying
    client = client_with([{ status: 200, body: "not json" }])
    error = assert_raises(Error) { client.me }
    assert_match(/invalid JSON/, error.message)
    assert_equal 1, requests.size
  end

  def test_retries_a_429_on_a_paid_post_honoring_retry_after
    client = client_with([problem(429, {}, { "Retry-After" => "3" }), json_response({ items: [] })])
    assert_equal({ "items" => [] }, client.companies.search(page_size: 1))
    assert_equal 2, requests.size
    assert_equal [3.0], delays
  end

  def test_honors_a_retry_after_date
    when_retry = (Time.now + 30).httpdate
    client = client_with([problem(503, {}, { "Retry-After" => when_retry }), json_response({})])
    client.me
    assert_in_delta 30, delays.first, 3
  end

  def test_falls_back_to_backoff_on_a_bad_retry_after
    client = client_with([problem(429, {}, { "Retry-After" => "soon" }), json_response({})])
    client.me
    assert_includes 0.375..0.5, delays.first
  end

  def test_waits_for_the_rate_limit_window_when_rate_limited
    client = client_with([problem(429, {}, { "x-ratelimit-window" => "00:00:35.5000000" }), json_response({})])
    client.me
    assert_equal 2, requests.size
    assert_equal [35.5], delays
  end

  def test_ignores_the_rate_limit_window_on_other_statuses
    client = client_with([problem(503, {}, { "x-ratelimit-window" => "00:00:35.5000000" }), json_response({})])
    client.me
    assert_operator delays.first, :<=, 0.5
  end

  def test_stops_when_the_server_asks_for_an_unreasonable_wait
    client = client_with([problem(429, {}, { "Retry-After" => "3600" })])
    assert_raises(RateLimitError) { client.me }
    assert_equal 1, requests.size
  end

  [408, 500, 502, 503, 504].each do |status|
    define_method(:"test_retries_a_get_on_#{status}") do
      client = client_with([problem(status), json_response({ userId: "u" })])
      assert_equal "u", client.me["userId"]
      assert_equal 2, requests.size
      assert_includes 0.375..0.5, delays.first
    end
  end

  {
    "connection_refused" => Errno::ECONNREFUSED,
    "socket_error" => SocketError,
    "read_timeout" => Net::ReadTimeout,
    "open_timeout" => Net::OpenTimeout,
    "reset" => Errno::ECONNRESET,
    "eof" => EOFError
  }.each do |name, failure|
    define_method(:"test_retries_a_get_after_#{name}") do
      client = client_with([failure, json_response({ userId: "u" })])
      assert_equal "u", client.me["userId"]
      assert_equal 2, requests.size
    end
  end

  PAID_POSTS = {
    "company_search" => ->(c) { c.companies.search },
    "people_search" => ->(c) { c.people.search },
    "enrich_by_properties" => ->(c) { c.companies.enrich_by_properties(name: "x") },
    "batch_enrich" => ->(c) { c.companies.enrich_batch(["a.com"]) },
    "bulk_enrichment" => ->(c) { c.companies.bulk_enrichment.create(["a.com"]) },
    "company_export" => ->(c) { c.companies.search_export.create(1) },
    "people_export" => ->(c) { c.people.search_export.create(1) },
    "person_enrich" => ->(c) { c.people.enrich("a@b.co") }
  }.freeze

  PAID_POSTS.each do |name, call|
    define_method(:"test_never_repeats_#{name}_after_an_ambiguous_failure") do
      { problem(503) => ServerError, Errno::ECONNRESET => APIConnectionError,
        Net::ReadTimeout => APITimeoutError }.each do |failure, error_class|
        WebMock.reset!
        client = client_with([failure])
        assert_raises(error_class) { call.call(client) }
        assert_equal 1, requests.size
      end
    end
  end

  {
    "company_count" => ->(c) { c.companies.count },
    "company_preview" => ->(c) { c.companies.preview },
    "people_count" => ->(c) { c.people.count },
    "people_preview" => ->(c) { c.people.preview },
    "country_search" => ->(c) { c.geo.search_countries },
    "state_search" => ->(c) { c.geo.search_states },
    "city_search" => ->(c) { c.geo.search_cities },
    "batch_cancel" => ->(c) { c.batches.cancel("id") }
  }.each do |name, call|
    define_method(:"test_retries_free_post_#{name}") do
      client = client_with([problem(500), json_response({})])
      call.call(client)
      assert_equal 2, requests.size
    end
  end

  def test_does_not_retry_client_errors
    client = client_with([problem(404)])
    assert_raises(NotFoundError) { client.me }
    assert_equal 1, requests.size
  end

  def test_gives_up_after_max_retries
    client = client_with([problem(503), problem(503), problem(503)], max_retries: 2)
    assert_raises(ServerError) { client.me }
    assert_equal 3, requests.size
  end

  def test_a_request_can_override_max_retries
    client = client_with([problem(503)])
    assert_raises(ServerError) { client.me(options: { max_retries: 0 }) }
    assert_equal 1, requests.size
  end

  def test_chains_the_original_transport_error
    client = client_with([Errno::ECONNREFUSED], max_retries: 0)
    error = assert_raises(APIConnectionError) { client.me }
    assert_kind_of Errno::ECONNREFUSED, error.cause
  end
end
