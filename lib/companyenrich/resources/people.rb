# frozen_string_literal: true

require_relative "batch_job"
require_relative "support"

module CompanyEnrich
  module Resources
    # Asynchronous export of a people search.
    class PersonSearchExport < BatchJob
      # Starts the export. It runs in the background and consumes credits as it progresses.
      def create(limit, filter: nil, semantic: nil, company: nil, expand: nil, options: nil)
        create_job({ limit: limit, filter: filter, semantic: semantic, company: company, expand: expand }, options)
      end
    end

    class People
      # @return [PersonSearchExport]
      attr_reader :search_export

      # @api private
      def initialize(http)
        @http = http
        @search_export = PersonSearchExport.new(http, "/v2/people/search/export")
      end

      # Retrieves a person by their CompanyEnrich ID.
      def get(person_id, expand: nil, options: nil)
        @http.request("GET", "/v2/people/#{Support.escape(person_id)}", query: { expand: expand }, options: options)
      end

      # Identifies a person from an email. Raises {NotFoundError} if there is no match.
      def enrich(email, expand: nil, options: nil)
        @http.request("POST", "/v2/people/enrich", body: { email: email, expand: expand }.compact, options: options)
      end

      # Finds a person's work email. Check +status+: only +found+ includes +email+.
      def find_email(person_id, domain: nil, options: nil)
        @http.request("GET", "/v2/people/#{Support.escape(person_id)}/email", query: { domain: domain },
                                                                              options: options)
      end

      # Returns one page of people matching filters, a semantic query, or a company query.
      def search(filter: nil, semantic: nil, company: nil, page_size: nil, cursor: nil, expand: nil, options: nil)
        body = {
          filter: filter, semantic: semantic, company: company,
          pageSize: page_size, cursor: cursor, expand: expand
        }.compact
        @http.request("POST", "/v2/people/search", body: body, options: options)
      end

      # Iterates over every matching person, fetching pages as needed. Accepts the same arguments as {#search}.
      # Credits are charged per page, so set +page_size+ close to what you will consume.
      # @return [Enumerator] when no block is given
      def search_all(cursor: nil, options: nil, **params, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          search(**params, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      # Counts matching people. Free.
      def count(filter: nil, semantic: nil, company: nil, options: nil)
        body = { filter: filter, semantic: semantic, company: company }.compact
        @http.request("POST", "/v2/people/search/count", body: body, retry_safe: true, options: options)
      end

      # Returns up to 10 person summaries. Free, but requires a plan with previews.
      def preview(filter: nil, semantic: nil, company: nil, options: nil)
        body = { filter: filter, semantic: semantic, company: company }.compact
        @http.request("POST", "/v2/people/search/preview", body: body, retry_safe: true, options: options)
      end
    end
  end
end
