# Dispatching::ServiceCode
#   has a short_name
#   has a description
#   should have the correct service code type (payroll, general)
#   report: id, rank, active, smart_home, chargeback)
# Payroll::InvoiceItemServiceCode
#   exists
#   save IISC Invoice Item ID
#   report: (SC id/name, II id/name)
# IISC Invoice Item (Payroll::InvoiceItem)
#   exists
#   has the correct invoice_item_type (Labor, Equipment, General)
#   has a description
#   report: (id, invoice_item_type, description)
# IISC Invoice Item is mapped to a part
#   report: (invoice_item.name, part.name, part.id

load 'sc-audit/my_loader.rb'
load 'sc-audit/my_reporter.rb'

include ActionView::Helpers::NumberHelper

class MyServiceCodeAnalyzer
  def initialize(output: './sc_analysis.csv', start_id: nil)
    @debugging = false

    @csv_headers = []
    @csv_data = []
    @csv_file_name = output

    @analysis_collection = set_start(start_id, all_service_codes)
  end

  def analyze_next
    report = MyReporter.new

    check_for_naming(report)
    check_for_on_boarding(report)
    check_for_valid_providers(report)
    check_for_possible_pay_grade_types(report)
    check_for_type_name(report)

    return report if type_checks_fail?(report)
    return report if invoice_item_mapping_checks_fail?(report)

    check_for_invoice_item_mappings(report)
    report
  end

  def analyze_all
    number_analyzed = 0
    @analysis_collection.each do |item|
      update_scode_cache(item)

      report = analyze_next
      @csv_data << report.csv_line
      @csv_headers = report.merged_csv_headers(@csv_headers)
      number_analyzed += 1
    end

    dump_csv
    number_analyzed
  end

  #++
  # short-cuts for various required components
  #
  def update_scode_cache(item)
    @current_service_code = item
  end

  def current_scode
    @current_service_code ||= @analysis_collection.peek
  end

  def type
    current_scode.service_code_type
  end

  def providers
    current_scode.service_provider_service_code_maps
  end

  def providers_list
    providers.map { |spm| "#{spm.service_provider.id}: #{spm.service_provider.name}" }.join(',')
  end

  def valid_types
    %w[general payroll].sort
  end

  def type_valid?
    valid_types.include?(type.name)
  end

  def invoice_item_map
    current_scode.invoice_item_service_codes
  end

  alias mapped_invoice_items invoice_item_map

  def possible_pay_grades
    collection = providers.map do |p|
      Payroll::PayGrade.joins(:pay_grade_type).where("payroll_pay_grade_types.service_provider_id = #{p.id}")
    end

    collection.flatten.map do |pg|
      "pg #{pg.id}: #{pg.name} (type: #{pg.pay_grade_type.name}/prov_id: #{pg.pay_grade_type.service_provider_id})"
    end
  end

  def latest_pay_grade_version
    pg_type = Payroll::PayGradeType.where(service_provider: provider, name: 'Equipment')
    pay_grade = Payroll::PayGrade.where(pay_grade_type: pg_type)
    pay_grade.first.pay_grade_versions.first
  end
  #
  ##--

  def abbreviated?
    current_scode.description != current_scode.short_name
  end

  def self_consistent?
    check(:type_valid?) && check(:has_abbreviation?)
  end

  def on_boarded?
    check('invoice_item_map.present?') &&
      check('mapped_invoice_items.count > 0') &&
      check('at_least_one_invoice_item_with_matching_name?') &&
      check('at_least_one_invoice_item_having_part_with_matching_name?') &&
      check('providers.present?') &&
      check('a_current_price?')
  end

  def at_least_one_invoice_item_with_matching_name?
    # this is the actual code of the method
    invoice_item_map.any? do |ii2sc_map|
      ii2sc_map.invoice_item.description == current_scode.short_name
    end
  end

  def at_least_one_invoice_item_having_part_with_matching_name?
    invoice_item_map.any? do |ii_map|
      ii = ii_map.invoice_item
      ii.invoice_item_parts.any? do |iip_map|
        check("'#{iip_map.part.number}' == '#{ii.description}'")
      end
    end
  end

  def a_current_price?
    # NOTE: this is a hack until we figure out how to deal with prices
    return true
    latest_pay_grade_version.invoice_item_pay_grades.first.present?
  end

  def dump_csv
    CSV.open(@csv_file_name, 'wb', headers: :first_row) do |csv|
      csv << @csv_headers
      @csv_data.each { |line| csv << line }
    end
    @csv_data.count + 1
  end

  def show_summary
    invoice_item_mappings = count_invoice_item_mappings
    provider_mappings = count_provider_mappings

    provider_mappings.each do |map_count, occurances|
      printf("%6s service codes have %i provider mappings\n",
             number_with_delimiter(occurances),
             map_count)
    end

    puts "\n"
    invoice_item_mappings.each do |map_count, occurances|
      printf("%6s service codes have %i invoice item mappings\n",
             number_with_delimiter(occurances),
             map_count)
    end
    nil
  end

  def count_provider_mappings
    mappings = {}
    # provider_mappings = Hash.new(0)

    mappings[0] = Dispatching::ServiceCode
                  .joins('LEFT JOIN dispatching_service_provider_service_code_maps spsc' \
                         '  ON dispatching_service_codes.id = spsc.service_code_id')
                  .where('spsc.service_provider_id IS NULL').count

    maps = Dispatching::ServiceProviderServiceCodeMap.group(:service_code_id).count(:service_provider_id)
    map_counts = maps.each_with_object(Hash.new(0)) { |(_, count), totals| totals[count] += 1 }
    mappings.merge!(map_counts)
  end

  def count_invoice_item_mappings
    mappings = {}
    # provider_mappings = Hash.new(0)

    mappings[0] = Dispatching::ServiceCode.joins(
      'LEFT JOIN payroll_invoice_item_service_codes iisc' \
      '  ON dispatching_service_codes.id = iisc.service_code_id'
    ).where('iisc.invoice_item_id IS NULL').count

    maps = Payroll::InvoiceItemServiceCode.group(:service_code_id).count(:invoice_item_id)
    map_counts = maps.each_with_object(Hash.new(0)) { |(_, count), totals| totals[count] += 1 }
    mappings.merge!(map_counts)
  end

  def toggle_debugging
    @debugging = !@debugging
  end

  #
  # [x]Creates an Inventory::Part for that number with the same name
  # [x] Creates a Payroll::InvoiceItem for that part (same name)
  # [x] Creates a Payroll::InvoiceItemPart for that II/Part pair
  # [x] Creates Dispatching::ServiceCode for that number with a descriptions same as the name
  # [x] Creates a Payroll::InvoiceItemServiceCode for that II/SC pair
  # [ ] Grabs the most recent Payroll::PayGrade for Asurion that it can find
  # [ ] Creates an InvoiceItemPayGrade for that Invoice Item/_cost_o
  #

  private

  attr_reader :debugging

  def all_service_codes
    Dispatching::ServiceCode
  end

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

  #++
  # Reporting methods for analyze_next
  #
  def check_for_naming(report)
    report.add(:short_name, current_scode.short_name)
    report.add(:description, current_scode.description)
    report.add(:abbreviated, abbreviated?)
  end

  def check_for_on_boarding(report)
    report.add(:properly_on_boarded, on_boarded?)
  end

  def check_for_valid_providers(report)
    if providers.blank?
      report.error('No service provider mapping')
    else
      report.warning("Has #{providers.count} providers (#{providers_list})") if providers.count > 1
      report.add_all(:providers, providers) do |spm|
        "#{spm.service_provider.id}: #{spm.service_provider.name}"
      end
    end
  end

  def check_for_possible_pay_grade_types(report)
    if possible_pay_grades.present?
      report.add_all(:possible_pay_grades, possible_pay_grades)
    elsif providers.present?
      report.error('Valid provider, but no pay grades')
    else
      report.error('No pay grades found')
    end
  end

  def check_for_type_name(report)
    report.add(:type, type.name) if type.present?
  end

  def check_for_invoice_item_mappings(report)
    # report all mapped items
    report.add_all(:mapped_invoice_items, mapped_invoice_items) do |i|
      "#{i.invoice_item.id}: #{i.invoice_item.description} [#{i.invoice_item.invoice_item_type.name}]"
    end

    # At least one should have the same name as the short code
    unless at_least_one_invoice_item_with_matching_name?
      report.error("No mapped inv item named #{current_scode.short_name}")
    end

    report_extra_invoice_item_parts_with_non_matching_names(report)
    report_extra_invoice_items(report)
  end

  def type_checks_fail?(report)
    if type.blank?
      report.error('(invalid--missing)')
      return true
    end

    unless type_valid?
      report.error("Invalid Type: #{type.name}")
      return true
    end
    false
  end

  def invoice_item_mapping_checks_fail?(report)
    # SC must be mapped to at least one invoice item
    if mapped_invoice_items.blank?
      report.add(:mapped_invoice_items, '')
      report.error('not mapped to any invoice items')
      return true
    end
    false
  end

  def report_extra_invoice_items(report)
    # NOTE: this is a hack: if we have more than one valid invoice_item mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping
    # exists with the same name as the ii.  This flags any others we see.
    invoice_item_map.each do |ii2sc_map|
      ii = ii2sc_map.invoice_item
      if ii.description != current_scode.short_name
        report.warning "-- Maps to multiple invoice items '#{current_scode.short_name}' " \
          "=> #{ii.description}"
      end
    end
    nil
  end

  def report_extra_invoice_item_parts_with_non_matching_names(report)
    # NOTE: this is a hack: if we have more than one valid part mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping
    # exists with the same name as the ii.  This flags any others we see.
    invoice_item_map.each do |ii_map|
      ii = ii_map.invoice_item
      ii.invoice_item_parts.each do |iip_map|
        if iip_map.part.number != ii.description
          report.warning "-- Map to inv item w/ multiple parts: #{ii.description} => #{iip_map.part.number}"
        end
      end
    end
    nil
  end
  #
  #--

  def check(test)
    retval = eval(test)
    if debugging
      warn "%% '#{test}' failed" unless retval
    end
    retval
  end
end

def test_it(test_id: 3081)
  # id 3139, "APL1037-KIT" is a known good ServiceCode, fully on-board and priced
  @sa = MyServiceCodeAnalyzer.new(start_id: test_id)
  @sa.toggle_debugging

  warn "% Testing w/SC #{@sa.current_scode.id} '#{@sa.current_scode.short_name}'"
  warn "? Fail: no service code found (id=#{test_id})" if @sa.current_scode.nil?
  warn '? Fail: no type found' if @sa.type.blank?
  warn '? Fail: no valid_types' if @sa.valid_types.blank?
  warn '? Fail: type_valid? wrong' unless @sa.type_valid?
  warn '? Fail: no invoice_item_map' if @sa.invoice_item_map.blank?
  warn '? Fail: no invoice_item' if @sa.invoice_item_map.blank?
  warn '? Fail: no show_summary' unless @sa.respond_to?(:show_summary)
  warn 'Showing @sa.summary:'
  @sa.show_summary
  warn "Is the test Service code on_boarded? #{@sa.on_boarded?}"

  @sa.toggle_debugging

  warn '-- Test complete'
end

def set_it_up
  outfile = 'sc-audit/sc_analysis.csv'
  @sa = MyServiceCodeAnalyzer.new(output: outfile)
  @sa.show_summary
  puts "\nAnalyzing. . ."
  @sa.analyze_all
  puts "@sa.dump_csv  to create the .CSV output file, #{outfile}"
end
puts 'defined: test_it(test_id: <existing_service_code_id>)   # default: 3081'
puts 'defined: set_it_up - summarize and analyze current service codes.  One step before CSV output.'

# Service Code is on-boarded:
# - Dispatching::ServiceCode exists
# - DSC has a Payroll::InvoiceItemServiceCode mapping and that II exists
# - II has the correct type (Labor, Equipment, General)
# - II is mapped to an Inventory::Part
#
# Service Code is priced:
# - The "#{service_provider} - #{service_code_type_name}" Payroll::InvoiceItemPayGradeType exists
# - A Payroll::PayGrade exists with that type
# - The latest Payroll::PayGradeVersion has an amount for that invoice item id
#
