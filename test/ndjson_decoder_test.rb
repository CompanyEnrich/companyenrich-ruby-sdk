# frozen_string_literal: true

require "test_helper"

class NdjsonDecoderTest < Minitest::Test
  def test_handles_chunks_that_split_a_multibyte_character
    decoder = CompanyEnrich::NdjsonDecoder.new
    payload = "{\"domain\":\"café.com\"}\n{\"domain\":\"b.com\"}\r\n\n{\"domain\":\"c.com\"}".b
    split = payload.index("\xC3".b) + 1
    records = decoder.feed(payload[0...split]) + decoder.feed(payload[split..]) + decoder.flush
    assert_equal(["café.com", "b.com", "c.com"], records.map { |record| record["domain"] })
  end

  def test_keeps_unicode_line_separators_inside_strings
    line = "{\"description\":\"one\u2028two\u0085three\"}\n"
    assert_equal [{ "description" => "one\u2028two\u0085three" }], CompanyEnrich::NdjsonDecoder.new.feed(line)
  end

  def test_reports_malformed_records
    error = assert_raises(CompanyEnrich::Error) { CompanyEnrich::NdjsonDecoder.new.feed("not json\n") }
    assert_match(/invalid NDJSON/, error.message)
  end

  def test_flush_is_empty_after_a_trailing_newline
    decoder = CompanyEnrich::NdjsonDecoder.new
    assert_equal [{ "a" => 1 }], decoder.feed("{\"a\":1}\n")
    assert_empty decoder.flush
  end

  def test_an_empty_chunk_keeps_the_partial_line
    decoder = CompanyEnrich::NdjsonDecoder.new
    assert_empty decoder.feed("{\"a\"")
    assert_empty decoder.feed("")
    assert_equal [{ "a" => 1 }], decoder.feed(":1}\n")
  end
end
