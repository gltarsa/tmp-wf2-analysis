# "Every Part should have an Invoice Item" - Kasey 12/2017
#

load 'sc-audit/my_loader.rb'
load 'sc-audit/my_reporter.rb'

include ActionView::Helpers::NumberHelper

class MyPartAnalyzer
  def initialize(output: './sc_part_analysis.csv', start_id: nil)
    @debugging = true

    @csv_headers = []
    @csv_data = []
    @csv_file_name = output

    @analysis_collection = set_start(start_id, parts_without_invoice_items)
  end

  def current_part
    @analysis_collection.peek
  end

  def analyze_next(part = nil)
    part = current_part if part.nil?

    report = MyReporter.new

    report.add(:number, part.number)
    report.add(:part_name, part.name)
    report.warning('Part name and number are identical') if part.name == part.number

    report.error('Not mapped to an invoice item')

    report
  end

  def analyze_all
    number_analyzed = 0
    @analysis_collection.each do |item|
      report = analyze_next(item)
      @csv_data << report.csv_line
      @csv_headers = report.merged_csv_headers(@csv_headers)
      number_analyzed += 1
    end

    dump_csv
    number_analyzed
  end

  def dump_csv
    CSV.open(@csv_file_name, 'wb', headers: :first_row) do |csv|
      csv << @csv_headers
      @csv_data.each { |line| csv << line }
    end
    @csv_data.count + 1
  end

  def show_summary
    invoice_item_mappings = Hash.new(0)

    all_parts.find_each do |p|
      invoice_item_mappings[p.invoice_item_parts.count] += 1
    end

    printf("%6s parts found\n", all_parts.count)
    invoice_item_mappings.each do |map_count, occurances|
      printf("%6s parts have %i invoice item mappings\n", number_with_delimiter(occurances), map_count)
    end
    nil
  end

  def toggle_debugging
    @debugging = !@debugging
  end

  def parts_without_invoice_items
    Inventory::Part
      .joins('LEFT JOIN payroll_invoice_item_parts iipmap ON inventory_parts.id = iipmap.part_id')
      .where('iipmap.invoice_item_id IS NULL')
      .order(:id)
  end

  def all_parts
    Inventory::Part
      .joins('FULL OUTER JOIN payroll_invoice_item_parts iipmap ON inventory_parts.id = iipmap.part_id')
      .order(:id)
  end

  private

  attr_reader :debugging

  def set_start(start_id, collection)
    start = collection.find_each
    return start if start_id.nil?

    begin
      id_to_seq_num(start_id, collection).times { start.next }
    rescue StopIteration
      warn '? starting record is beyond the end of the collection'
      return nil
    end
    start
  end

  def id_to_seq_num(start_id, collection)
    seq_num = 0
    collection.find_each.with_index { |p, i| seq_num = i + 1 if p.id == start_id }
    raise "? Starting part, #{start_id}, not found!!" if seq_num.zero?
    seq_num - 1
  end
end

def test_it(test_id: 751)
  # id 751, "IP5S-ET-BLK-T2" is a Part known not to have an invoice item mapping

  @pa = MyPartAnalyzer.new(start_id: test_id)
  @pa.toggle_debugging

  warn "% Testing w/Part #{@pa.current_part.id} #{@pa.current_part.number}'"
  warn "? Fail: no parts found (id=#{test_id})" if @pa.current_part.nil?
  warn '? Fail: cannot analyze part' unless @pa.analyze_next
  warn '? Fail: no show_summary' unless @pa.respond_to?(:show_summary)
  warn 'Showing @pa.summary:'
  @pa.show_summary

  @pa.toggle_debugging

  warn '-- Test complete'
end

def set_it_up
  outfile = 'sc-audit/part_analysis.csv'
  @pa = MyPartAnalyzer.new(output: outfile)
  @pa.show_summary
  puts "\nAnalyzing. . ."
  puts "  #{@pa.analyze_all} items analyzed"
  puts "@pa.dump_csv  to create the .CSV output file, #{outfile}"
end
puts 'defined: test_it(test_id: <existing_id>)   # default: 751'
puts 'defined: set_it_up - summarize and analyze codes.  One step before CSV output.'
