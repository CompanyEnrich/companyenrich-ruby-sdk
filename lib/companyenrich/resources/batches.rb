# frozen_string_literal: true

require_relative "../errors"
require_relative "support"

module CompanyEnrich
  module Resources
    class Batches
      DEFAULT_POLL_INTERVAL = 2.0

      # @api private
      def initialize(http)
        @http = http
      end

      # Returns one page of your batches, newest first.
      def list(kind: nil, page_size: nil, cursor: nil, options: nil)
        @http.request("GET", "/v2/batches", query: { kind: kind, pageSize: page_size, cursor: cursor },
                                            options: options)
      end

      # Iterates over all of your batches, newest first.
      # @return [Enumerator] when no block is given
      def list_all(kind: nil, page_size: nil, cursor: nil, options: nil, &block)
        enumerator = Support.paginate(cursor) do |next_cursor|
          list(kind: kind, page_size: page_size, cursor: next_cursor, options: options)
        end
        Support.iterate(enumerator, block)
      end

      # Retrieves a batch's status and progress.
      def get(batch_id, options: nil)
        @http.request("GET", "/v2/batches/#{Support.escape(batch_id)}", options: options)
      end

      # Stops remaining work. Results that were already charged stay downloadable.
      def cancel(batch_id, options: nil)
        @http.request("POST", "/v2/batches/#{Support.escape(batch_id)}/cancel", retry_safe: true, options: options)
      end

      # Streams the raw HTTP outcome of each request in the batch.
      # @return [Enumerator] when no block is given
      def raw_results(batch_id, sig: nil, options: nil, &block)
        enumerator = Enumerator.new do |yielder|
          path = "/v2/batches/#{Support.escape(batch_id)}/results"
          @http.stream_ndjson(path, query: { sig: sig }, options: options) { |record| yielder << record }
        end
        Support.iterate(enumerator, block)
      end

      # Polls until the batch is +completed+ or +cancelled+, then returns its final status.
      # Yields the latest status after every check. Raises {APITimeoutError} if +timeout+ seconds
      # pass first, and waits indefinitely by default.
      def wait_for_completion(batch_id, poll_interval: DEFAULT_POLL_INTERVAL, timeout: nil, options: nil)
        deadline = timeout && (now + timeout)
        while true # rubocop:disable Style/InfiniteLoop
          batch = get(batch_id, options: options)
          yield batch if block_given?
          return batch if %w[completed cancelled].include?(batch["status"])

          wait = poll_interval
          if deadline
            remaining = deadline - now
            raise APITimeoutError, "Batch #{batch_id} did not finish within #{timeout} seconds" if remaining <= 0

            wait = [poll_interval, remaining].min
          end
          @http.pause(wait)
        end
      end

      private

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
