# Non-Small Parts Invoice Items should map to at least one Payroll Service Code
# Invoice Items should map to at least one Dispatching Service Code (same as above?)
# Invoice Items should have a Service Provider
# Invoice Items should have an entry in the Recon Invoice Item Map (may have?)
#
# Bonus:
#   The item name of Invoice Items of type Equipment should map to at least one part with a matching number
#   Invoice Items of type Labor should (could?) map to a different name
#
#
# TODO: change code to process through an ActiveRecordRelation based on what is needed:
#   Small parts only for small parts checks
#   Items with necessary parts
#   Basic idea: use the DB to do the checking, not Ruby

load 'sc-audit/my_loader.rb'
load 'sc-audit/my_reporter.rb'

include ActionView::Helpers::NumberHelper

class MyInvoiceItemAnalyzer
  def initialize(output: './invoice_item_analysis.csv', start_id: nil)
    @debugging = true

    @csv_headers = []
    @csv_data = []
    @csv_file_name = output
    @current_item = nil

    @analysis_collection = set_start(start_id, all_items)
  end

  def update_item_cache(item)
    @current_item = item
  end

  def current_item
    @current_item ||= @analysis_collection.peek
  end

  def analyze_next
    report = MyReporter.new

    add_names(report)
    check_non_small_parts_to_have_at_least_one_payroll_service_code_mapping(report)
    maybe_check_for_at_least_one_dispatching_service_code_mapping(report)
    check_for_a_service_provider_mapping(report)
    check_for_a_recon_invoice_item_mapping(report)
    bonus_check_equipment_for_matching_part_number(report)

    report
  end

  def analyze_all
    number_analyzed = 0
    @analysis_collection.each do |item|
      update_item_cache(item)
      report = analyze_next
      @csv_data << report.csv_line
      @csv_headers = report.merged_csv_headers(@csv_headers)
      number_analyzed += 1
    end

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
    payroll_service_code_mappings = Hash.new(0)

    all_items.find_each do |i|
      service_code_mappings = Payroll::InvoiceItemServiceCode.where(invoice_item: current_item)
      payroll_service_code_mappings[service_code_mappings.count] += 1
    end

    printf("%6s invoice items found\n", number_with_delimiter(all_items.count))
    payroll_service_code_mappings.each do |map_count, occurances|
      printf("%6s invoice items have %i service code mappings\n", number_with_delimiter(occurances), map_count)
    end
    nil
  end

  def toggle_debugging
    @debugging = !@debugging
  end

  def all_items
    Payroll::InvoiceItem
      .select('payroll_invoice_items.*, payroll_invoice_item_types.name, payroll_invoice_item_parts.part_id, payroll_invoice_item_parts.invoice_item_id, p.name, p.number')
      .from('payroll_invoice_items as payroll_invoice_items')
      .joins('FULL OUTER JOIN payroll_invoice_item_parts AS payroll_invoice_item_parts ON payroll_invoice_items.id = payroll_invoice_item_parts.invoice_item_id')
      .joins('FULL OUTER JOIN inventory_parts AS p ON payroll_invoice_item_parts.part_id = p.id')
      .joins('full outer join payroll_invoice_item_types as payroll_invoice_item_types on payroll_invoice_items.invoice_item_type_id = payroll_invoice_item_types.id')
      .order('payroll_invoice_items.id ASC')

      # .joins('RIGHT JOIN recon_invoice_item_maps ' \
      #        'ON payroll_invoice_items.id = recon_invoice_item_maps.invoice_item_id')
      # .joins('RIGHT JOIN payroll_invoice_item_parts ' \
      #        'ON payroll_invoice_items.id = payroll_invoice_item_parts.invoice_item_id')
      # .order(:id)
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
    raise "? Starting invoice item, #{start_id}, not found!!" if seq_num.zero?
    seq_num - 1
  end

  def category_small_parts
    @category_small_parts ||= Inventory::PartCategory.find_by(name: 'Small Parts')
  end

  def add_names(report)
    report.add(:id, current_item.id)
    report.add(:type, current_item.invoice_item_type.name)
    report.add(:description, current_item.description)
  end

  def maybe_check_for_at_least_one_dispatching_service_code_mapping(report)
    # report.warning("dispatch SC mapping check not implemented yet")
    # the mappings for this are in #check_for_at_least_one_payroll_service_code_mapping,
    # so this check has already happened.
  end

  def check_non_small_parts_to_have_at_least_one_payroll_service_code_mapping(report)
    mappings = Payroll::InvoiceItemServiceCode.where(invoice_item: current_item)
    if mappings.empty?
      sc = '?none?'
      sc = 'n/a' if current_item.invoice_item_parts.any? { |p| p.part.part_category == category_small_parts }

      report.add(:sc_short_name, sc)
      report.add(:sc_description, sc)
      return
    end

    report.add_all(:sc_short_name, mappings) { |m| "#{m.service_code.short_name}" }
    report.add_all(:sc_description, mappings) do |m|
      if m.service_code.description == current_item.description
        '<same>'
      else
        "#{m.service_code.description}"
      end
    end
  end

  def check_for_a_service_provider_mapping(report)
    mappings = current_item.invoice_item_maps
    if mappings.empty?
      report.add(:service_providers, '?none?')
    else
      report.add_all(:service_providers, mappings) { |m| "#{m.service_provider.name}" }
    end
  end

  def check_for_a_recon_invoice_item_mapping(report)
    rii_mappings = Recon::InvoiceItemMap.where(invoice_item: current_item)
    if rii_mappings.empty?
      report.add(:rii_map_values, '?none?')
    else
      report.add_all(:rii_map_values, rii_mappings) do |riim|
        if riim.value == report.line_data[:sc_short_name]
          'ok'
        else
          "#{riim.value}"
        end
      end
    end
  end

  def bonus_check_equipment_for_matching_part_number(report)
    if current_item.invoice_item_type.name != 'Equipment'
      report.add(:part_match, 'n/a')
      return
    end

    parts = current_item.invoice_item_parts

    if parts.empty?
      report.add(:part_match, '?none?')
      return
    end

    matching_parts = parts.all.select { |p| p.part.number == current_item.description }
    if matching_parts.empty?
      report.add(:part_match, '?NO-MATCH?')
      return
    end

    report.add_all(:part_match, matching_parts) do |p|
      if p.part.number == current_item.description
        "Y"
      else
        "other: #{p.part.number}"
      end
    end
    report.add(:part_count, matching_parts.count) if matching_parts.count > 1
  end
end

def test_it(test_id: 3)
  # id 3, "Set Up Extra Mirror TV" is an invoice item known to have good set of mappings

  @pii = MyInvoiceItemAnalyzer.new(start_id: test_id)
  @pii.toggle_debugging

  warn "% Testing w/InvoiceItem #{@pii.current_item.id} #{@pii.current_item.description}'"
  warn "? Fail: no invoice items found (id=#{test_id})" if @pii.current_item.nil?
  warn '? Fail: cannot analyze invoice item' unless @pii.analyze_next
  warn '? Fail: no show_summary' unless @pii.respond_to?(:show_summary)
  warn 'Showing @pii.summary:'
  # @pii.show_summary

  @pii.toggle_debugging

  warn '-- Test complete'
end

def set_it_up
  outfile = 'sc-audit/invoice_item_analysis.csv'
  @pii = MyInvoiceItemAnalyzer.new(output: outfile)
  puts "\nAnalyzing. . ."
  puts "  #{@pii.analyze_all} items analyzed"
  puts "@pii.dump_csv  to create the .CSV output file, #{outfile}"
end
puts 'defined: test_it(test_id: <existing_id>)'
puts 'defined: set_it_up - summarize and analyze codes.  One step before CSV output.'
