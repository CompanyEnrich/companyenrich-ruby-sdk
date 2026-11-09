# frozen_string_literal: true

module CompanyEnrich
  module Resources
    class Industries
      # @api private
      def initialize(http)
        @http = http
      end

      # Lists all industries and their NAICS code prefixes. Free.
      def list(options: nil)
        @http.request("GET", "/v2/industries", options: options)
      end
    end

    # Suggests up to 10 values for a search filter, ordered by popularity. Free.
    class Autocomplete
      # @api private
      def initialize(http, path)
        @http = http
        @path = path
      end

      def autocomplete(query, options: nil)
        @http.request("GET", @path, query: { query: query }, options: options)
      end
    end
  end
end
