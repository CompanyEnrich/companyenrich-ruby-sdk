# CompanyEnrich Ruby SDK

[![Gem Version](https://img.shields.io/gem/v/companyenrich)](https://rubygems.org/gems/companyenrich)

The official Ruby client for the [CompanyEnrich API](https://companyenrich.com): company and people enrichment, filter, semantic and lookalike search, work emails, and bulk jobs.

It requires Ruby 3.1 or newer and has no runtime dependencies.

## Install

```sh
gem install companyenrich
```

Or add it to your `Gemfile`:

```
gem "companyenrich"
```

## Quick start

Create an API key in your [dashboard](https://companyenrich.com/dashboard) and keep it secret.

```ruby
require "companyenrich"

# Reads COMPANYENRICH_API_KEY from the environment, or pass api_key: "your-api-key".
client = CompanyEnrich::Client.new

company = client.companies.enrich("stripe.com")
puts company["name"], company["employees"]
```

Responses are plain hashes with the API's field names as string keys. Optional fields can be absent or `nil`.

Method arguments are `snake_case` keywords. Hashes you pass, such as `filter`, use the API's own field names.

## Companies

```ruby
# Add paid data to a lookup. Each expansion costs extra credits.
detailed = client.companies.enrich("stripe.com", expand: %w[technologies workforce])

# Up to 50 domains at once. Check each item's status.
batch = client.companies.enrich_batch(["stripe.com", "adyen.com"])
batch["items"].each do |item|
  puts item["domain"], item.dig("company", "name") if item["status"] == "found"
end

# Filter search
page = client.companies.search(
  filter: { country: "US", employees: ["51-200", "201-500"], categories: "saas" },
  page_size: 25
)
puts page["items"].size, page["nextCursor"]

# Free count of the same query
total = client.companies.count(filter: { country: "US" })
puts total["count"]
```

## People

```ruby
results = client.people.search(
  filter: { domain: "stripe.com", seniority: %w[c-suite founder] },
  page_size: 10
)

person = client.people.enrich("jane@stripe.com")

lookup = client.people.find_email(person["id"], domain: "stripe.com")
puts lookup["email"], lookup["certainty"] if lookup["status"] == "found"
```

## Semantic and lookalike search

Semantic search finds companies or people from a plain-language description. Lookalike search finds companies similar to ones you already know. A company search can use either mode but not both, and either can be combined with `filter`. `search_all` accepts the same arguments as `search`.

| Search | Credits per result |
| --- | --- |
| Companies by filters | 1 |
| Companies by description | 2 |
| Lookalike companies | 5 |
| People, in any mode | 2 |

Paid expansions cost extra, and an empty result costs one result's base price. To try a query for free, pass the same arguments to `companies.preview` or `people.preview`, which need a plan with previews.

### Companies by description

By default, the API reads attributes such as location and size from your query and applies them. `interpretation` shows what it inferred.

```ruby
results = client.companies.search(
  semantic: { query: "saas companies in Turkey" },
  page_size: 25
)

results["items"].each do |company|
  puts company["domain"], company["description"]
end

p results.dig("interpretation", "filter") # Inferred filters, such as the country
p results.dig("interpretation", "boost") # Inferred ranking boosts, such as the category
```

Filters you pass take priority over inferred values of the same kind. Set `autoFilter: false` to turn inference off, or set `weight` (0 to 1) to control how much semantic similarity affects ranking.

```ruby
filtered = client.companies.search(
  semantic: { query: "AI tools for hospitals", autoFilter: false },
  filter: { country: "US", employees: ["51-200", "201-500"] },
  page_size: 25
)
```

### Lookalike companies

Pass 1 to 10 seed domains. Use `minScore` (0 to 1) to require a minimum similarity.

```ruby
similar = client.companies.search(
  lookalike: { domains: ["stripe.com", "adyen.com"] },
  filter: { country: "US", employees: ["51-200", "201-500"] },
  page_size: 25
)

scores = similar["scores"] || {} # Scores are not probabilities
similar["items"].each do |company|
  puts company["domain"], scores[company["id"]]
end
```

Keep results in the order returned rather than sorting them by score.

### People by description

The API turns your query into person filters, such as role, seniority and country, plus a description of their current companies. `interpretation` shows both. A query it can't infer any filters from is rejected with an error, so include something concrete like a role or location.

```ruby
people = client.people.search(
  semantic: { query: "marketing leaders at Series B fintech startups in London" },
  page_size: 25
)

people["items"].each do |person|
  puts person["name"], person["position"]
end

p people["interpretation"] # The inferred filters and company description
```

### People at matching companies

Use `company` to find people by the kind of company they work at. These searches cover people at the 1,000 best-matching companies.

```ruby
# Executives at companies matching a description
executives = client.people.search(
  filter: { seniority: %w[c-suite vp] },
  company: { semantic: { query: "AI tools for hospitals" } },
  page_size: 25
)

# Executives at companies similar to your best customers
similar_teams = client.people.search(
  filter: { seniority: %w[c-suite vp] },
  company: { lookalike: { domains: ["stripe.com", "adyen.com"] } },
  page_size: 25
)
```

## Pagination

`search` returns one page. The `*_all` methods take a block, or return a lazy `Enumerator` that requests pages as you consume them.

```ruby
client.companies.search_all(filter: { country: "TR" }, page_size: 100) do |company|
  puts company["domain"]
end

first_ten = client.people.search_all(filter: { domain: "stripe.com" }, page_size: 10).first(10)
```

These are available as `companies.search_all`, `people.search_all`, `batches.list_all`, and `geo.search_countries_all`, `geo.search_states_all` and `geo.search_cities_all`.

Search credits are charged for every result on a fetched page, even if you stop iterating partway through it. Set `page_size` close to the number of results you plan to use.

## Bulk jobs

Bulk enrichment and search exports run in the background.

```ruby
job = client.companies.bulk_enrichment.create(["stripe.com", "adyen.com"])

client.batches.wait_for_completion(job["id"]) do |batch|
  puts "#{batch['progress']['succeeded']}/#{batch['progress']['total']}"
end

client.companies.bulk_enrichment.stream(job["id"]) do |record|
  puts record["domain"], record.dig("company", "name") if record["success"]
end
```

`companies.bulk_enrichment`, `companies.search_export` and `people.search_export` share the same methods:

| Method | Returns |
| --- | --- |
| `create(...)` | The new batch's status |
| `stream(id)` | Each record in turn, best for large jobs |
| `results(id)` | One JSON document with every record |
| `csv(id)` | The CSV as a string |
| `csv_chunks(id)` | The CSV as raw bytes, for writing to a file |

## Errors

Failed requests raise a subclass of `CompanyEnrich::APIError`, which carries `status`, `title`, `detail`, `errors` (field-level validation messages) and `trace_id` (include it when contacting support).

```ruby
begin
  client.companies.enrich("example.invalid")
rescue CompanyEnrich::NotFoundError
  puts "No company found"
rescue CompanyEnrich::PaymentRequiredError
  puts "Out of credits, or not included in this plan"
rescue CompanyEnrich::APIError => e
  puts e.status, e.detail, e.trace_id
end
```

| Status | Class |
| --- | --- |
| 400 | `BadRequestError` |
| 401 | `AuthenticationError` |
| 402 | `PaymentRequiredError` |
| 403 | `PermissionDeniedError` |
| 404 | `NotFoundError` |
| 422 | `ValidationError` |
| 429 | `RateLimitError` |
| 5xx | `ServerError` |
| Other | `APIError` |

`APIConnectionError` and `APITimeoutError` cover requests that never received a response or were cut off. Everything above extends `CompanyEnrich::Error`.

## Retries and timeouts

Failed requests are retried up to twice with exponential backoff.

| Failure | GET and free POST endpoints | Other POST endpoints |
| --- | --- | --- |
| 429 rate limit | Retried | Retried |
| 408, 5xx, connection error, timeout | Retried | Not retried |

POST requests that consume credits or start a job are not repeated after an ambiguous failure, because the first attempt may already have been charged or created a batch. A download that fails partway through is never restarted, so you won't receive duplicate records.

## Configuration

```ruby
configured = CompanyEnrich::Client.new(api_key: "your-api-key", timeout: 30, max_retries: 4)

# Every method accepts per-request options.
configured.me(options: { timeout: 5, max_retries: 0 })
```

| Option | Default | Description |
| --- | --- | --- |
| `api_key` | `COMPANYENRICH_API_KEY` | Your API key |
| `base_url` | `https://api.companyenrich.com` | API origin, for proxies |
| `timeout` | `120` | Timeout in seconds. `nil` disables it |
| `max_retries` | `2` | Retries after the first attempt |
| `default_headers` | none | Headers added to every request |

Each request uses its own connection, so one client can be shared across threads.

## API reference

| SDK method | Endpoint |
| --- | --- |
| `companies.get(id)` | `GET /v2/companies/{companyId}` |
| `companies.enrich(domain)` | `GET /v2/companies/enrich` |
| `companies.enrich_by_properties(...)` | `POST /v2/companies/enrich` |
| `companies.enrich_batch(domains)` | `POST /v2/companies/enrich/batch` |
| `companies.autocomplete(query)` | `GET /v2/companies/autocomplete` |
| `companies.workforce(...)` | `GET /v2/companies/workforce` |
| `companies.search(...)` | `POST /v2/companies/search` |
| `companies.count(...)` | `POST /v2/companies/search/count` |
| `companies.preview(...)` | `POST /v2/companies/search/preview` |
| `companies.bulk_enrichment.*` | `/v2/companies/enrich/bulk` |
| `companies.search_export.*` | `/v2/companies/search/export` |
| `people.get(id)` | `GET /v2/people/{personId}` |
| `people.enrich(email)` | `POST /v2/people/enrich` |
| `people.find_email(id)` | `GET /v2/people/{personId}/email` |
| `people.search(...)` | `POST /v2/people/search` |
| `people.count(...)` | `POST /v2/people/search/count` |
| `people.preview(...)` | `POST /v2/people/search/preview` |
| `people.search_export.*` | `/v2/people/search/export` |
| `batches.list(...)` | `GET /v2/batches` |
| `batches.get(id)` | `GET /v2/batches/{id}` |
| `batches.cancel(id)` | `POST /v2/batches/{id}/cancel` |
| `batches.raw_results(id)` | `GET /v2/batches/{id}/results` |
| `batches.wait_for_completion(id)` | Polls `GET /v2/batches/{id}` |
| `geo.regions` | `GET /v2/geo/regions` |
| `geo.country(code)` | `GET /v2/geo/countries/{countryCode}` |
| `geo.search_countries(...)` | `POST /v2/geo/countries` |
| `geo.search_states(...)` | `POST /v2/geo/states` |
| `geo.search_cities(...)` | `POST /v2/geo/cities` |
| `industries.list` | `GET /v2/industries` |
| `keywords.autocomplete(query)` | `GET /v2/keywords/autocomplete` |
| `technologies.autocomplete(query)` | `GET /v2/technologies/autocomplete` |
| `positions.autocomplete(query)` | `GET /v2/positions/autocomplete` |
| `me` | `GET /v2/me` |

See the [API documentation](https://api.companyenrich.com/openapi/v2.json) for parameters and credit costs.

## Development

```sh
bundle install
bundle exec rake
```

To release, bump `VERSION` in `lib/companyenrich/version.rb` and push to `main`. The publish workflow runs the checks and publishes that version to RubyGems if it is new.

## License

MIT
