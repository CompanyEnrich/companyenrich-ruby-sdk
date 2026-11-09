# frozen_string_literal: true

require "test_helper"

class ResourcesTest < Minitest::Test
  include TestHelpers
  include CompanyEnrich

  # Every operation in the OpenAPI spec and the SDK call that reaches it.
  OPERATIONS = {
    "GET /v2/companies/{companyId}" => ->(c) { c.companies.get(UUID, expand: ["keywords"]) },
    "GET /v2/companies/enrich" => ->(c) { c.companies.enrich("stripe.com") },
    "POST /v2/companies/enrich" => ->(c) { c.companies.enrich_by_properties(name: "Stripe") },
    "POST /v2/companies/enrich/batch" => ->(c) { c.companies.enrich_batch(["stripe.com"]) },
    "GET /v2/companies/autocomplete" => ->(c) { c.companies.autocomplete("stri") },
    "POST /v2/companies/enrich/bulk" => ->(c) { c.companies.bulk_enrichment.create(["a.com"]) },
    "POST /v2/companies/search/export" => ->(c) { c.companies.search_export.create(10) },
    "POST /v2/people/search/export" => ->(c) { c.people.search_export.create(10) },
    "GET /v2/companies/enrich/bulk/{id}/results" => ->(c) { c.companies.bulk_enrichment.results(UUID) },
    "GET /v2/companies/search/export/{id}/results" => ->(c) { c.companies.search_export.results(UUID) },
    "GET /v2/people/search/export/{id}/results" => ->(c) { c.people.search_export.results(UUID) },
    "GET /v2/companies/workforce" => ->(c) { c.companies.workforce(domain: "stripe.com") },
    "POST /v2/companies/search" => ->(c) { c.companies.search(page_size: 1) },
    "POST /v2/companies/search/count" => ->(c) { c.companies.count },
    "POST /v2/companies/search/preview" => ->(c) { c.companies.preview },
    "POST /v2/people/search" => ->(c) { c.people.search(page_size: 1) },
    "POST /v2/people/search/count" => ->(c) { c.people.count },
    "POST /v2/people/search/preview" => ->(c) { c.people.preview },
    "GET /v2/industries" => ->(c) { c.industries.list },
    "GET /v2/keywords/autocomplete" => ->(c) { c.keywords.autocomplete("saas") },
    "GET /v2/technologies/autocomplete" => ->(c) { c.technologies.autocomplete("react") },
    "GET /v2/positions/autocomplete" => ->(c) { c.positions.autocomplete("cto") },
    "GET /v2/me" => lambda(&:me),
    "GET /v2/batches" => ->(c) { c.batches.list(page_size: 5) },
    "GET /v2/batches/{id}" => ->(c) { c.batches.get(UUID) },
    "POST /v2/batches/{id}/cancel" => ->(c) { c.batches.cancel(UUID) },
    "GET /v2/batches/{id}/results" => ->(c) { c.batches.raw_results(UUID).to_a },
    "GET /v2/people/{personId}" => ->(c) { c.people.get(42) },
    "POST /v2/people/enrich" => ->(c) { c.people.enrich("a@b.co") },
    "GET /v2/people/{personId}/email" => ->(c) { c.people.find_email(42) },
    "GET /v2/geo/regions" => ->(c) { c.geo.regions },
    "GET /v2/geo/countries/{countryCode}" => ->(c) { c.geo.country("US") },
    "POST /v2/geo/countries" => ->(c) { c.geo.search_countries(query: "uni") },
    "POST /v2/geo/states" => ->(c) { c.geo.search_states(query: "cal") },
    "POST /v2/geo/cities" => ->(c) { c.geo.search_cities(query: "par") }
  }.freeze

  def test_every_spec_operation_is_mapped
    spec = JSON.parse(File.read(File.expand_path("../openapi/v2.json", __dir__)))
    operations = spec.fetch("paths").flat_map do |path, item|
      item.keys.select { |method| %w[get post put patch delete].include?(method) }
          .map { |method| "#{method.upcase} #{path}" }
    end
    assert_equal operations.sort, OPERATIONS.keys.sort
  end

  OPERATIONS.each do |operation, invoke|
    define_method(:"test_reaches #{operation}") do
      method, template = operation.split
      client = client_with([json_response({ items: [] })])
      invoke.call(client)
      request = requests.first
      assert_equal method.downcase.to_sym, request.method
      assert_match(/\A#{template.gsub(/\{[^}]+\}/, "[^/]+")}\z/, request.uri.path)
    end
  end

  def test_walks_every_page_forwarding_the_cursor_and_params
    client = client_with(
      [
        json_response({ items: [{ id: "1" }, { id: "2" }], nextCursor: "c2" }),
        json_response({ items: [{ id: "3" }], nextCursor: "c3" }),
        json_response({ items: [{ id: "4" }] })
      ]
    )
    companies = client.companies.search_all(page_size: 2).to_a
    assert_equal(%w[1 2 3 4], companies.map { |company| company["id"] })
    assert_equal(
      [{ "pageSize" => 2 }, { "pageSize" => 2, "cursor" => "c2" }, { "pageSize" => 2, "cursor" => "c3" }],
      requests.map { |request| body_of(request) }
    )
  end

  def test_iterates_with_a_block
    client = client_with([json_response({ items: [{ id: 1 }] })])
    seen = []
    client.people.search_all { |person| seen << person["id"] }
    assert_equal [1], seen
  end

  def test_does_not_fetch_another_page_after_the_caller_stops
    client = client_with([json_response({ items: [{ id: 1 }, { id: 2 }], nextCursor: "c2" })])
    assert_equal([{ "id" => 1 }], client.people.search_all(page_size: 2).first(1))
    assert_equal 1, requests.size
  end

  def test_makes_no_request_until_iteration_starts
    client = client_with([])
    client.companies.search_all
    assert_empty requests
  end

  def test_starts_from_a_caller_supplied_cursor
    client = client_with([json_response({ items: [] })])
    client.geo.search_cities_all(cursor: "resume").to_a
    assert_equal({ "cursor" => "resume" }, body_of(requests.first))
  end

  def test_paginates_batches_through_the_query_string
    client = client_with(
      [json_response({ items: [{ id: "a" }], nextCursor: "next" }), json_response({ items: [{ id: "b" }] })]
    )
    assert_equal(%w[a b], client.batches.list_all(kind: "company-enrichment").map { |batch| batch["id"] })
    assert_includes query_pairs(requests[1]), %w[cursor next]
    assert_includes query_pairs(requests[1]), %w[kind company-enrichment]
  end

  def test_surfaces_a_failure_on_a_later_page
    client = client_with([json_response({ items: [{ id: "1" }], nextCursor: "c2" }), problem(404)])
    assert_raises(NotFoundError) { client.companies.search_all.to_a }
  end

  def test_selects_the_download_format_and_forwards_the_signature
    client_with([json_response({ results: [] })]).companies.search_export.results(UUID, sig: "abc")
    assert_equal "/v2/companies/search/export/#{UUID}/results", requests.first.uri.path
    assert_includes query_pairs(requests.first), %w[format json]
    assert_includes query_pairs(requests.first), %w[sig abc]
  end

  def test_streams_ndjson_records
    client = client_with([{ status: 200, body: "{\"index\":0}\n{\"index\":1}\n{\"index\":2}" }])
    records = client.companies.bulk_enrichment.stream(UUID).to_a
    assert_equal([0, 1, 2], records.map { |record| record["index"] })
    assert_includes query_pairs(requests.first), %w[format ndjson]
    assert_equal "*/*", requests.first.headers["Accept"]
  end

  def test_raises_the_api_error_instead_of_streaming_a_failed_response
    client = client_with([problem(404, { title: "Not Found" })])
    assert_raises(NotFoundError) { client.batches.raw_results(UUID).to_a }
  end

  def test_returns_csv_text_and_strips_a_byte_order_mark
    client = client_with([{ status: 200, body: "\xEF\xBB\xBFindex,domain\n0,caf\xC3\xA9.com\n".b }])
    text = client.companies.bulk_enrichment.csv(UUID)
    assert_equal "index,domain\n0,café.com\n", text
    assert_equal Encoding::UTF_8, text.encoding
    assert_includes query_pairs(requests.first), %w[format csv]
  end

  def test_yields_raw_csv_chunks
    client = client_with([{ status: 200, body: "index,domain\n" }])
    assert_equal "index,domain\n", client.people.search_export.csv_chunks(UUID).to_a.join
  end

  def status(value)
    json_response({ id: UUID, status: value })
  end

  def test_polls_until_the_batch_is_finished
    client = client_with([status("pending"), status("running"), status("completed")])
    seen = []
    batch = client.batches.wait_for_completion(UUID, poll_interval: 7.0) { |update| seen << update["status"] }
    assert_equal "completed", batch["status"]
    assert_equal %w[pending running completed], seen
    assert_equal 3, requests.size
    assert_equal [7.0, 7.0], delays
  end

  def test_treats_cancelling_as_unfinished_and_cancelled_as_finished
    client = client_with([status("cancelling"), status("cancelled")])
    assert_equal "cancelled", client.batches.wait_for_completion(UUID)["status"]
  end

  def test_raises_when_the_batch_deadline_passes
    client = client_with([status("running")])
    error = assert_raises(APITimeoutError) { client.batches.wait_for_completion(UUID, timeout: 0) }
    assert_match(/did not finish/, error.message)
  end

  def test_workforce_requires_exactly_one_lookup
    client = client_with([])
    [{}, { company_id: UUID, domain: "a.com" }].each do |arguments|
      error = assert_raises(ArgumentError) { client.companies.workforce(**arguments) }
      assert_match(/exactly one/, error.message)
    end
    assert_empty requests
  end

  def test_workforce_sends_the_company_id_as_id
    client_with([json_response({})]).companies.workforce(company_id: UUID, cursor: "older")
    assert_includes query_pairs(requests.first), ["id", UUID]
    assert_includes query_pairs(requests.first), %w[cursor older]
  end
end
