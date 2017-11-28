include ActionView::Helpers::NumberHelper

class MyServiceCodeChecker
  attr_reader :short_name, :service_code

  def initialize(short_name:)
    @short_name = short_name
    self
  end

  def service_code
    @service_code ||= Dispatching::ServiceCode.find_by(short_name: short_name)
  end

  def type
    service_code.service_code_type
  end

  def valid_types
    %w[general payroll]
  end

  def type_valid?
    valid_types.include(type)
  end

  def valid_types_consistent?
    existing_types ||= Dispatching::ServiceCodeType.all.map { |t| t.name }
    valid_types.sort == existing_types.sort
  end

  def has_abbreviation?
    service_code.description != service_code.short_name
  end

  def self_consistent?
    check(:type_valid?) && check(:has_abbreviation?)
  end

  def invoice_item_map
    @invoice_item_map ||= service_code.invoice_item_service_codes
  end

  def mapped_invoice_item
    service_code.invoice_item_service_codes
  end

  def show_stats
    mappings = Hash.new(0)
    Dispatching::ServiceCode.find_each do |sc|
      mappings[sc.invoice_item_service_codes.count] += 1
    end

    mappings.each do |map_count, occurances|
      puts "%6s service codes have %i mappings\n" % [number_with_delimiter(occurances), map_count]
    end
    nil
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
  def valid?
    short_name? &&
      description?
  end

  def on_boarded?
    exists? &&
      invoice_item_mapping.exists? &&
      mapped_invoice_item.exists? &&
      mapped_invoice_item.type.exists?
    # and more...
  end
  #
  # [ ]Creates an Inventory::Part for that number with the same name
  # [x] Creates a Payroll::InvoiceItem for that part (same name)
  # [ ] Creates a Payroll::InvoiceItemPart for that II/Part pair
  # [x] Creates Dispatching::ServiceCode for that number with a descriptions same as the name
  # [x] Creates a Payroll::InvoiceItemServiceCode for that II/SC pair
  # [ ] Grabs the most recent Payroll::PayGrade for Asurion that it can find
  # [ ] Creates an InvoiceItemPayGrade for that Invoice Item/_cost_o
  #

  private

  def check(method)
    retval = self.send(method)
    puts "%% #{method} failed"
    retval
  end
end

@scc = MyServiceCodeChecker.new(short_name: 'SAM1942-KIT')
puts "@scc initialized as MyServiceCodeChecker.new(#{@scc.short_name})"

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
