load 'sc-audit/my_loader.rb'

include ActionView::Helpers::NumberHelper
class MyServiceCodeChecker
  attr_reader :current_name

  def initialize()
    clear_memos
    @analyzed_data = {}
    raise "? Service Code Types in DB out of sync. " +
      "#{existing_types} != #{valid_types}" unless valid_types_consistent?
    self
  end

  def analyze(provider:, short_name:)
    clear_memos
    @provider = valid_service_provider(provider)

    @current_name = short_name
    raise "?already seen this short_name: #{current_name}" if @analyzed_data[current_name].present?

    @analyzed_data[current_name] = {
      mappings: mapped_invoice_items,
      mappings_count: mapped_invoice_items.count,
      warnings: [],
      errors: []
    }

    @analyzed_data[current_name][:errors] << "this additional error"
  end

  def service_code
    @service_code ||= Dispatching::ServiceCode.find_by(short_name: current_name)
  end

  def type
    service_code.service_code_type
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

  def has_abbreviation?
    service_code.description != service_code.short_name
  end

  def self_consistent?
    check(:type_valid?) && check(:has_abbreviation?)
  end

  def invoice_item_map
    service_code.invoice_item_service_codes
  end

  alias mapped_invoice_items invoice_item_map

  def mapped_invoice_items
    service_code.invoice_item_service_codes
  end

  def show_summary
    mappings = Hash.new(0)
    Dispatching::ServiceCode.find_each do |sc|
      mappings[sc.invoice_item_service_codes.count] += 1
    end

    mappings.each do |map_count, occurances|
      puts "%6s service codes have %i mappings\n" % [number_with_delimiter(occurances), map_count]
    end
    nil
  end

  def show_stats
    Dispatching::ServiceCode.find_each do |sc|
      display_missing_mapping(sc) # if when?
    end
  end

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
  def minimally_valid?
   check("service_code.short_name.present?") &&
     check("service_code.description.present?")
  end

  def on_boarded?
    valid_so_far = check("minimally_valid?") &&
      check("invoice_item_map.present?") &&
      mapped_invoice_items.count > 0 &&
      at_least_one_invoice_item_with_matching_name? &&
      at_least_one_invoice_item_having_part_with_matching_name? &&
      has_a_current_price?
  end

  def at_least_one_invoice_item_with_matching_name?
    hack_show_extra_invoice_items

    # this is the actual code of the method
    invoice_item_map.any? do |ii2sc_map|
      ii2sc_map.invoice_item.description == current_name
    end
  end

  def at_least_one_invoice_item_having_part_with_matching_name?
    hack_show_extra_invoice_item_parts_with_non_matching_names

    invoice_item_map.any? do |map|
      ii = map.invoice_item
      ii.invoice_item_parts.any? do |map|
        check("'#{map.part.number}' == '#{ii.description}'")
      end
    end
  end

  def has_a_current_price?
    latest_pay_grade_version.invoice_item_pay_grades.first.present?
  end

  def latest_pay_grade_version
    pg_type = Payroll::PayGradeType.where(service_provider: @provider, name: 'Equipment')
    pay_grade = Payroll::PayGrade.where(pay_grade_type: pg_type)
    pay_grade.first.pay_grade_versions.first
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

  def hack_show_extra_invoice_items
    # NOTE: this is a hack: if we have more than one valid invoice_item mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping
    # exists with the same name as the ii.  This flags any others we see.
    binding.pry
    invoice_item_map.each do |ii2sc_map|
      ii = ii2sc_map.invoice_item
      if ii.description != current_name
        puts "-- Note: SC '#{current_name}' has a map to multiple invoice items '#{current_name}' => #{ii.description}"
      end
    end
    nil
  end

  def hack_show_extra_invoice_item_parts_with_non_matching_names
    # NOTE: this is a hack: if we have more than one valid part mapped, display a warning
    # It works because our current definition of "valid ii" is that one mapping exists with the same name as the ii.  This flags any others we see.
    invoice_item_map.each do |map|
      ii = map.invoice_item
      ii.invoice_item_parts.each do |map|
        if map.part.number != ii.description
          puts "-- Note: SC #{current_name} has a map to an invoice item w/ multiple parts: #{ii.description} => #{map.part.number}"
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
    puts "%% '#{test}' failed" unless retval
    retval
  end

  def valid_service_provider(name)
    provider = Dispatching::ServiceProvider.find_by(name: name)
    raise "?name: #{name} not found in Dispatching::ServiceProvider table!" if provider.nil?
    provider
  end
end

def set_it_up
  @service_code_names = MyLoader.new(file: 'sc-audit/service_code_check_list.csv')
  puts "loader instantiated as @items and #{@items.count} items loaded from '#{file}'"

  @scc = MyServiceCodeChecker.new
  puts "@scc initialized as MyServiceCodeChecker.new"
end

def do_it
  @service_code_names.each do |short_name|
    @scc.analyze(short_name: short_name)
  end

  @scc.show_summary
  @scc.show_stats
end

def test_it(provider = 'Asurion', test_id)
  # id 3987, "SAM1942-KIT" is a known good ServiceCode, fully on-board and priced
  test_sc = Dispatching::ServiceCode.find(test_id)
  @scc = MyServiceCodeChecker.new

  @scc.analyze(provider: provider, short_name: test_sc.short_name)

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
  $stderr.puts "Is the test Service code minimally_valid? #{@scc.minimally_valid?}"
  $stderr.puts "Is the test Service code on_boarded? #{@scc.on_boarded?}"

  $stderr.puts "? Fail: no show_stats" unless @scc.respond_to?(:show_stats)

  $stderr.puts "-- Test complete"
end


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
