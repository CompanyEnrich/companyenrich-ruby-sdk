# frozen_string_literal: true

require_relative "batch_job"
require_relative "support"

module CompanyEnrich
  module Resources
    # Asynchronous enrichment of up to 10,000 domains.
    class CompanyBulkEnrichment < BatchJob
      # Starts the job. It runs in the background and consumes credits as it progresses.
      def create(domains, expand: nil, wait_for_enrichment: nil, options: nil)
        create_job({ domains: domains, expand: expand, waitForEnrichment: wait_for_enrichment }, options)
      end
    end

    # Asynchronous export of a company search.
    class CompanySearchExport < BatchJob
      # Starts the export. It runs in the background and consumes credits as it progresses.
      def create(limit, filter: nil, semantic: nil, lookalike: nil, expand: nil, options: nil)
        create_job({ limit: limit, filter: filter, semantic: semantic, lookalike: lookalike, expand: expand }, options)
      end
    end

    class Companies
      # @return [CompanyBulkEnrichment]
      attr_reader :bulk_enrichment
      # @return [CompanySearchExport]
      attr_reader :search_export

      # @api private
      def initialize(http)
        @http = http
        @bulk_enrichment = CompanyBulkEnrichment.new(http, "/v2/companies/enrich/bulk")
        @search_export = CompanySearchExport.new(http, "/v2/companies/search/export")
      end

      # Retrieves a stored company by its CompanyEnrich ID.
      def get(company_id, expand: nil, options: nil)
        @http.request("GET", "/v2/companies/#{Support.escape(company_id)}", query: { expand: expand }, options: options)
      end

      # Enriches a company by domain. Raises {NotFoundError} when there is no match.
      def enrich(domain, expand: nil, wait_for_enrichment: nil, options: nil)
        query = { domain: domain, expand: expand, waitForEnrichment: wait_for_enrichment }
        @http.request("GET", "/v2/companies/enrich", query: query, options: options)
      end

      # Enriches a company from identifying properties such as its name or LinkedIn URL.
      def enrich_by_properties(name: nil, linkedin_url: nil, linkedin_id: nil, twitter_url: nil, facebook_url: nil,
                               instagram_url: nil, youtube_url: nil, expand: nil, options: nil)
        body = {
          name: name, linkedinUrl: linkedin_url, linkedinId: linkedin_id, twitterUrl: twitter_url,
          facebookUrl: facebook_url, instagramUrl: instagram_url, youtubeUrl: youtube_url, expand: expand
        }.compact
        @http.request("POST", "/v2/companies/enrich", body: body, options: options)
      end

      # Enriches up to 50 domains in one request.
      def enrich_batch(domains, expand: nil, wait_for_enrichment: nil, options: nil)
        body = { domains: domains, expand: expand, waitForEnrichment: wait_for_enrichment }.compact
        @http.request("POST", "/v2/companies/enrich/batch", body: body, options: options)
      end

      # Suggests up to 10 companies whose domain matches +query+.
      def autocomplete(query, options: nil)
        @http.request("GET", "/v2/companies/autocomplete", query: { query: query }, options: options)
      end

      # Retrieves workforce insights for exactly one of +company_id+ or +domain+.
      # Pass +nextCursor+ from the response as +cursor+ to go back another 12 months.
      def workforce(company_id: nil, domain: nil, cursor: nil, options: nil)
        raise ArgumentError, "Provide exactly one of `company_id:` or `domain:`." if company_id.nil? == domain.nil?

        query = { id: company_id, domain: domain, cursor: cursor }
        @http.request("GET", "/v2/companies/workforce", query: query, options: options)
      end

      # Returns one page of companies matching filters, a semantic query, or lookalike seeds.
      def search(filter: nil, semantic: nil, lookalike: nil, page_size: nil, cursor: nil, expand: nil, options: nil)
        body = {
          filter: filter, semantic: semantic, lookalike: lookalike,
          pageSize: page_size, cursor: cursor, expand: expand
        }.compact
        @http.request("POST", "/v2/companies/search", body: body, options: options)
      end

      # Iterates over every matching company, fetching pages as needed. Accepts the same arguments as {#search}.
      # Credits are charged per page, so set +page_size+ close to what you will consume.
      # @return [Enumerator] when no block is given
      def search_all(cursor: nil, options: nil, **params, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          search(**params, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      # Counts matching companies. Free.
      def count(filter: nil, semantic: nil, lookalike: nil, options: nil)
        body = { filter: filter, semantic: semantic, lookalike: lookalike }.compact
        @http.request("POST", "/v2/companies/search/count", body: body, retry_safe: true, options: options)
      end

      # Returns up to 25 company summaries. Free, but requires a plan with previews.
      def preview(filter: nil, semantic: nil, lookalike: nil, options: nil)
        body = { filter: filter, semantic: semantic, lookalike: lookalike }.compact
        @http.request("POST", "/v2/companies/search/preview", body: body, retry_safe: true, options: options)
      end
    end
  end
end
