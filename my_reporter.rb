# MyReporter
#
# A quickie class to build a csv line over time and them dump it upon request.
# It builds only a single line

class MyReporter
  attr_reader :line_headers, :line_data, :line_errors, :line_warnings

  def initialize
    @line_data = {}
    @line_errors = []
    @line_warnings = []
  end

  def add(heading, value)
    @line_data[heading] = value
  end

  def add_all(heading, values)
    combined = values.map do |value|
      if block_given?
        yield(value)
      else
        "#{value}"
      end
    end.join('|')
    add(heading, combined)
  end

  def error(msg)
    @line_errors << msg
  end

  def warning(msg)
    @line_warnings << msg
  end

  def csv_line
    @line_data.delete(:errors)
    @line_data.delete(:warnings)
    add_all(:errors, @line_errors)
    add_all(:warnings, @line_warnings)
    @line_data
  end

  def merged_csv_headers(other_headers)
    headers = @line_data.keys - [:errors, :warnings]
    other_headers -= [:errors, :warnings]

    other_headers.each { |h| headers << h unless headers.include?(h) }
    headers << :errors << :warnings
  end
end

def reporter_test
  @my_line = MyReporter.new
  @my_line.add(:first_col, "first data")
  @my_line.error("first error")
  @my_line.warning("first_warning")
  @my_line.add(:second_col, "second data")
  test = %w[one two three]
  @my_line.add_all(:multiple_items, test) { |item| "--#{item}--" }
  test2 = []
  @my_line.add_all(:empty_collection, test2) { |item| "00#{item}00" }
  @my_line.error("second error")
  @my_line.warning("second warning")
  other_headers = [:other1, :errors, :other2, :warnings, :other3]
  puts "Headers: #{@my_line.merged_csv_headers(other_headers)}"
  puts "Data: #{@my_line.csv_line}"
end
puts "defined reporter_test"
