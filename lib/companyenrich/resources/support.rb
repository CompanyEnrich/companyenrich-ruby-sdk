# frozen_string_literal: true

require "erb"

module CompanyEnrich
  module Resources
    # Helpers shared by the resource classes.
    # @api private
    module Support
      module_function

      def escape(value)
        ERB::Util.url_encode(value.to_s)
      end

      # Runs the enumerator with the caller's block, or returns it for lazy use.
      def iterate(enumerator, block)
        block ? enumerator.each(&block) : enumerator
      end

      # Builds a lazy enumerator that requests a page only when it is needed.
      def paginate(first_cursor, &fetch_page)
        Enumerator.new do |yielder|
          cursor = first_cursor
          fetching = true
          while fetching
            page = fetch_page.call(cursor)
            page.fetch("items").each { |item| yielder << item }
            cursor = page["nextCursor"]
            fetching = !(cursor.nil? || cursor.empty?)
          end
        end
      end
    end
  end
end
