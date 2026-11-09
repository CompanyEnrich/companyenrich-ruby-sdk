# frozen_string_literal: true

require "json"

require_relative "errors"

module CompanyEnrich
  # Splits a byte stream into JSON records, keeping partial lines between chunks.
  # @api private
  class NdjsonDecoder
    def initialize
      @buffer = String.new(encoding: Encoding::BINARY)
    end

    # @return [Array] the records completed by this chunk
    def feed(chunk)
      @buffer << chunk.b
      lines = @buffer.split("\n", -1)
      @buffer = lines.pop || String.new(encoding: Encoding::BINARY)
      parse(lines)
    end

    # @return [Array] the final record, if the stream did not end with a newline
    def flush
      rest = @buffer
      @buffer = String.new(encoding: Encoding::BINARY)
      parse([rest])
    end

    private

    def parse(lines)
      lines.reject { |line| line.strip.empty? }.map do |line|
        JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        raise Error, "The API returned an invalid NDJSON record"
      end
    end
  end
end
