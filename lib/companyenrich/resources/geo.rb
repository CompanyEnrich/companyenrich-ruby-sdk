# frozen_string_literal: true

require_relative "support"

module CompanyEnrich
  module Resources
    # Geographic reference data for search filters. Every endpoint here is free.
    class Geo
      # @api private
      def initialize(http)
        @http = http
      end

      # Lists all regions and their country codes.
      def regions(options: nil)
        @http.request("GET", "/v2/geo/regions", options: options)
      end

      # Retrieves a country by its two-letter code.
      def country(country_code, options: nil)
        @http.request("GET", "/v2/geo/countries/#{Support.escape(country_code)}", options: options)
      end

      def search_countries(query: nil, page_size: nil, cursor: nil, options: nil)
        search("/v2/geo/countries", { query: query, pageSize: page_size, cursor: cursor }, options)
      end

      # @return [Enumerator] when no block is given
      def search_countries_all(cursor: nil, options: nil, **params, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          search_countries(**params, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      def search_states(country_codes: nil, query: nil, page_size: nil, cursor: nil, options: nil)
        body = { countryCodes: country_codes, query: query, pageSize: page_size, cursor: cursor }
        search("/v2/geo/states", body, options)
      end

      # @return [Enumerator] when no block is given
      def search_states_all(cursor: nil, options: nil, **params, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          search_states(**params, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      def search_cities(state_ids: nil, country_codes: nil, query: nil, page_size: nil, cursor: nil, options: nil)
        body = { stateIds: state_ids, countryCodes: country_codes, query: query, pageSize: page_size, cursor: cursor }
        search("/v2/geo/cities", body, options)
      end

      # @return [Enumerator] when no block is given
      def search_cities_all(cursor: nil, options: nil, **params, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          search_cities(**params, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      private

      def search(path, body, options)
        @http.request("POST", path, body: body.compact, retry_safe: true, options: options)
      end
    end
  end
end
