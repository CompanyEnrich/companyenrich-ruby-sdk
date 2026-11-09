# frozen_string_literal: true

require_relative "support"

module CompanyEnrich
  module Resources
    # An asynchronous job: create it, wait with +batches.wait_for_completion+, then download its results.
    class BatchJob
      # @api private
      def initialize(http, path)
        @http = http
        @path = path
      end

      # Downloads every settled record as one JSON document.
      def results(batch_id, sig: nil, options: nil)
        @http.request("GET", results_path(batch_id), query: { format: "json", sig: sig }, options: options)
      end

      # Streams settled records one at a time. Prefer this for large jobs.
      # @return [Enumerator] when no block is given
      def stream(batch_id, sig: nil, options: nil, &block)
        enumerator = Enumerator.new do |yielder|
          query = { format: "ndjson", sig: sig }
          @http.stream_ndjson(results_path(batch_id), query: query, options: options) do |record|
            yielder << record
          end
        end
        Support.iterate(enumerator, block)
      end

      # Downloads the results as CSV text. Use {#csv_chunks} for large jobs.
      # @return [String]
      def csv(batch_id, sig: nil, options: nil)
        csv_chunks(batch_id, sig: sig, options: options).to_a.join
                                                        .force_encoding(Encoding::UTF_8).delete_prefix("﻿")
      end

      # Yields the CSV download as raw bytes, for example to write it to a file.
      # @return [Enumerator] when no block is given
      def csv_chunks(batch_id, sig: nil, options: nil, &block)
        enumerator = Enumerator.new do |yielder|
          query = { format: "csv", sig: sig }
          @http.stream_chunks(results_path(batch_id), query: query, options: options) do |chunk|
            yielder << chunk
          end
        end
        Support.iterate(enumerator, block)
      end

      private

      def create_job(body, options)
        @http.request("POST", @path, body: body.compact, options: options)
      end

      def results_path(batch_id)
        "#{@path}/#{Support.escape(batch_id)}/results"
      end
    end
  end
end
