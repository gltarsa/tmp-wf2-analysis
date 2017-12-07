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

# count is the number of service codes to analyze from Dispatching::ServiceCodes
# start is the ordinal position of the first code to analyze
class MyServiceCodeAnalyzer
  attr_reader :current_name

  def initialize(output: "./sc_analysis.csv", start: 1)
    clear_memos

    @debugging = false
    @csv_headers = []
    @csv_data = []
    @csv_file_name = output

    raise "? Service Code Types in DB out of sync. " +
      "#{existing_types} != #{valid_types}" unless valid_types_consistent?

    @service_codes = Dispatching::ServiceCode.find_each
    begin
      start.times { @service_codes.next } if start > 0
    rescue StopIteration => e
      $stderr.puts "? starting record is beyond the end of the collection"
      return nil
    end

    self
  end

  def current_name
    service_code.short_name
  end

  def analyze_next
    clear_memos

    report = MyReporter.new

    report.add(:short_name, service_code.short_name)
    report.add(:description, service_code.description)
    report.add(:abbreviated, abbreviated?)

    report.add(:properly_on_boarded, on_boarded?)

    # SC has one or more valid providers
    if providers.present?
      report.warning("Has #{providers.count} providers (#{providers_list})") if providers.count > 1
      report.add_all(:providers, providers) do |spm|
        "#{spm.service_provider.id}: #{spm.service_provider.name}"
      end
    else
      report.error("No service provider mapping")
    end

    # There are one or more pay_grade types for that provider
    #

    # SC: show possible pay_grade types
    if possible_pay_grades.present?
      report.add_all(:possible_pay_grades, possible_pay_grades)
    else
      if providers.present?
        report.error("Valid provider, but no pay grades")
      else
        report.error("No pay grades found")
      end
    end

    # SC has a valid type
    # An error here stops further checking
    unless type.present?
      report.error("(invalid--missing)")
      return report
    end

    unless type_valid?
      report.error("Invalid Type: #{type.name}")
      return report
    end

    report.add(:type, type.name) if type.present?

    # SC must be mapped to at least one invoice item
    # an error here stops further checking
    unless mapped_invoice_items.present?
      report.add(:mapped_invoice_items, "")
      report.error("not mapped to any invoice items")
      return report
    end

    # report all mapped items
    report.add_all(:mapped_invoice_items, mapped_invoice_items) do |i|
      "#{i.invoice_item.id}: #{i.invoice_item.description} [#{i.invoice_item.invoice_item_type.name}]"
    end

    # At least one should have the same name as the short code
    report.error("No mapped invoice item named #{service_code.short_name}") unless at_least_one_invoice_item_with_matching_name?

    report_extra_invoice_item_parts_with_non_matching_names(report)
    report_extra_invoice_items(report)
    report
  end

  def analyze_all
    loop do |sc|
      report = analyze_next
      @csv_data << report.csv_line
      @csv_headers = report.merged_csv_headers(@csv_headers)
    end

    dump_csv
    nil
  end

  #++
  # short-cuts for various required components
  #
  def service_code
    # @service_code ||= Dispatching::ServiceCode.find_each.next
    @service_code ||= @service_codes.next
  end

  def type
    service_code.service_code_type
  end

  def providers
    service_code.service_provider_service_code_maps
  end

  def providers_list
    providers.map {|spm| "#{spm.service_provider.id}: #{spm.service_provider.name}"}.join(',')
  end

  def valid_types
    %w[general payroll].sort
  end

  def type_valid?
    valid_types.include?(type.name)
  end

  def existing_types
    @existing_types ||= Dispatching::ServiceCodeType.order(:name).map { |t| t.name }
  end

  def valid_types_consistent?
    valid_types == existing_types
  end

  def invoice_item_map
    service_code.invoice_item_service_codes
  end

  alias mapped_invoice_items invoice_item_map

  def mapped_invoice_items
    service_code.invoice_item_service_codes
  end

  def possible_pay_grades
    providers.map do |p|
      Payroll::PayGrade.joins(:pay_grade_type).where("payroll_pay_grade_types.service_provider_id = #{p.id}")
    end.flatten.map do |pg|
      "pg #{pg.id}: #{pg.name} (type: #{pg.pay_grade_type.name}/prov_id: #{pg.pay_grade_type.service_provider_id})"
    end
  end

  def latest_pay_grade_version
    pg_type = Payroll::PayGradeType.where(service_provider: @provider, name: 'Equipment')
    pay_grade = Payroll::PayGrade.where(pay_grade_type: pg_type)
    pay_grade.first.pay_grade_versions.first
  end
  #
  ##--

  def abbreviated?
    service_code.description != service_code.short_name
  end

  def self_consistent?
    check(:type_valid?) && check(:has_abbreviation?)
  end

  def on_boarded?
    valid_so_far =
      check("invoice_item_map.present?") &&
      check("mapped_invoice_items.count > 0") &&
      check("at_least_one_invoice_item_with_matching_name?") &&
      check("at_least_one_invoice_item_having_part_with_matching_name?") &&
      check("providers.present?") &&
      check("has_a_current_price?")
  end

  def at_least_one_invoice_item_with_matching_name?
    # this is the actual code of the method
    invoice_item_map.any? do |ii2sc_map|
      ii2sc_map.invoice_item.description == current_name
    end
  end

  def at_least_one_invoice_item_having_part_with_matching_name?
    invoice_item_map.any? do |map|
      ii = map.invoice_item
      ii.invoice_item_parts.any? do |map|
        check("'#{map.part.number}' == '#{ii.description}'")
      end
    end
  end

  def has_a_current_price?
    # NOTE: this is a hack until we figure out how to deal with prices
    binding.pry
    return true
    latest_pay_grade_version.invoice_item_pay_grades.first.present?
  end

  def dump_csv
    CSV.open(@csv_file_name, "wb", headers: :first_row) do |csv|
      csv << @csv_headers
      @csv_data.each { |line| csv << line }
    end
    @csv_data.count + 1
  end

  def show_summary
    invoice_item_mappings = Hash.new(0)
    provider_mappings = Hash.new(0)

    Dispatching::ServiceCode.find_each do |sc|
      invoice_item_mappings[sc.invoice_item_service_codes.count] += 1
      provider_mappings[providers.count] += 1
    end

    provider_mappings.each do |map_count, occurances|
      puts "%6s service codes have %i provider mappings\n" % [number_with_delimiter(occurances), map_count]
    end
    puts "\n"
    invoice_item_mappings.each do |map_count, occurances|
      puts "%6s service codes have %i invoice item mappings\n" % [number_with_delimiter(occurances), map_count]
    end
    nil
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

  def report_extra_invoice_items(report)
    # NOTE: this is a hack: if we have more than one valid invoice_item mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping
    # exists with the same name as the ii.  This flags any others we see.
    invoice_item_map.each do |ii2sc_map|
      ii = ii2sc_map.invoice_item
      if ii.description != current_name
        report.warning "-- Maps to multiple invoice items '#{current_name}' => #{ii.description}"
      end
    end
    nil
  end

  def report_extra_invoice_item_parts_with_non_matching_names(report)
    # NOTE: this is a hack: if we have more than one valid part mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping exists with the same name as the ii.  This flags any others we see.
    invoice_item_map.each do |map|
      ii = map.invoice_item
      ii.invoice_item_parts.each do |map|
        if map.part.number != ii.description
          report.warning "-- Has a map to an invoice item w/ multiple parts: #{ii.description} => #{map.part.number}"
        end
      end
    end
    nil
  end

  def clear_memos
    @provider = nil
    @service_code = nil
    @existing_types = nil
  end

  def check(test)
    retval = eval(test)
    $stderr.puts "%% '#{test}' failed" unless retval if debugging
    retval
  end
end

def test_it(test_id: 3139)
  # id 3139, "SAM1866-KIT" is a known good ServiceCode, fully on-board and priced
  seq_num = 0
  Dispatching::ServiceCode.all.each_with_index { |sc, i| seq_num = i if sc.id == test_id }
  $stderr.puts "? Test SC, #{test_id}, not found!!  Using first one in table." if seq_num.zero?

  @scc = MyServiceCodeAnalyzer.new(start: seq_num)
  @scc.toggle_debugging

  $stderr.puts "% Testing w/SC #{@scc.service_code.id} (seq: #{seq_num}) '#{@scc.service_code.short_name}'"
  $stderr.puts "? Fail: no service code found (id=#{test_id})" if @scc.service_code.nil?
  $stderr.puts "? Fail: no type found" unless @scc.type.present?
  $stderr.puts "? Fail: no valid_types" unless @scc.valid_types.present?
  $stderr.puts "? Fail: type_valid? wrong" unless @scc.type_valid?
  $stderr.puts "? Fail: no existing_types" unless @scc.existing_types.present?
  $stderr.puts "? Fail: existing types inconsistent" unless @scc.valid_types_consistent?
  $stderr.puts "? Fail: no invoice_item_map" unless @scc.invoice_item_map.present?
  $stderr.puts "? Fail: no invoice_item" unless @scc.invoice_item_map.present?
  $stderr.puts "? Fail: no show_summary" unless @scc.respond_to?(:show_summary)
  # $stderr.puts "Showing @scc.summary:"
  # @scc.show_summary
  $stderr.puts "Is the test Service code on_boarded? #{@scc.on_boarded?}"

  $stderr.puts "? Fail: no show_stats" unless @scc.respond_to?(:show_stats)
  @scc.toggle_debugging

  $stderr.puts "-- Test complete"
end

def set_it_up
  outfile = 'sc-audit/sc_analysis.csv'
  @scc = MyServiceCodeAnalyzer.new(output: outfile)
  @scc.show_summary
  puts "\nAnalyzing. . ."
  @scc.analyze_all
  puts "@scc.dump_csv  to create the .CSV output file, #{outfile}"
end
puts 'defined: test_it(test_id: <existing_service_code_id>)   # default: 3139'
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
