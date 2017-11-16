#
# Creates an Inventory::Part for that number with the same name
# Creates a Payroll::InvoiceItem for that part (same name)
# Creates a Payroll::InvoiceItemPart for that II/Part pair
# Creates Dispatching::ServiceCode for that number with a descriptions same as the name
# Creates a Payroll::InvoiceItemServiceCode for that II/SC pair
# Grabs the most recent Payroll::PayGrade for Asurion that it can find
#    Updates all $0.00 costs that invoice item/paygrade (Payroll::InvoiceItemPayGrade)
# Creates an InvoiceItemPayGrade for that Invoice Item/_cost_o
#

class MyLoader
  include Enumerable

  attr_reader :data, :provider

  def initialize(file: 'sc-audit/asurion-service-codes.csv')
    @data = get_max_pricedata_from_file(file)
    @current = @data.first
    self
  end

  def [](index)
    @data[index]
  end

  def each
    i = 0
    while i < @data.length
      yield @data[i]
      i += 1
    end
  end

  def part_exists?(number)
    Inventory::Part.find_by(number: number).present?
  end

  private

  def get_max_pricedata_from_file(file_name)
    raw_data = CSV.read(file_name, headers: true).map(&:to_h)
    curated_data = {}
    raw_data.each do |item|
      code = item['number']
      curated_data[code] ||= item
      curated_data[code] = item if curated_data[code]['cost'] < item['cost']
    end
    curated_data.sort.map(&:last)
  end
end

class MyBuilder
  attr_reader :undo_buffer, :data, :latest_pg_version  # visible for testing, need not be public

  def initialize(provider: 'Asurion')
    @provider = valid_service_provider(provider)
    @pg_type = Payroll::PayGradeType.where(service_provider: @provider, name: 'Equipment')
    @pay_grade = Payroll::PayGrade.where(pay_grade_type: @pg_type)
    @created_items = []
    @undo_buffer = []
    self
  end

  def latest_pg_version
    @pay_grade.first.pay_grade_versions.first
  end

  def create_stuff(number, cost)
    debug 24, "+\nCalling create_stuff(#{number}, #{cost})"
    part = find_or_create_part(number)
    invoice_item = find_or_create(Payroll::InvoiceItem, description: "item: #{number}")
    ii_part_map = find_or_create(Payroll::InvoiceItemPart, invoice_item_id: invoice_item.id, part_id: part.id)
    service_code = find_or_create(Dispatching::ServiceCode,
                                  description: "Service Code: #{number}",
                                  short_name: "sc: #{number}")
    ii_sc_map = find_or_create(Payroll::InvoiceItemServiceCode,
                               service_code_id: service_code.id,
                               invoice_item_id: invoice_item.id)
    collect_created_items(item: invoice_item, cost: cost)
    nil
  end

  def undo
    debug 24, "-\nCalling undo()"
    @undo_buffer.each do |item|
      debug 10, "- Destroying #{item.inspect}"
      if item.persisted?
        begin
          item.destroy!
        rescue StandardError => e
          show 4, "? failed: #{e}"
        end
      else
        show 10, "% Not present in DB: #{item}, id: #{item.try(:id)}\n\n"
      end
    end
    nil
  end

  def set_amounts
    amounts = build_amounts
    new_pg_version = latest_pg_version.new_version(latest_pg_version.effective + 1.day, amounts)

    save_for_undo(new_pg_version)
    nil
  end

  def build_amounts
    amounts = {}
    @created_items.each do |data|
      amounts.merge!(data[:item].id => data[:cost])
    end
    amounts
  end

  private

  def valid_service_provider(name)
    provider = Dispatching::ServiceProvider.find_by(name: name)
    raise "?name: #{name} not found in Dispatching::ServiceProvider table!" if provider.nil?
    provider
  end

  def find_or_create_part(number)
    debug 1, ":find_or_create_part(#{number})"
    model = Inventory::Part
    thing = model.find_by(number: number)
    if thing.nil?
      find_or_create(model, number: number, name: number)
    else
      thing
    end
  end

  def find_or_create(model, attrs)
    debug 1, ":find_or_create(#{model}, #{attrs})"
    attributes = default_attributes(model).merge(attrs)
    thing = model.find_by(attributes)
    if thing.present?
      show 10, "% #{model} already exists with attrs: #{attrs}\n\n" unless thing.nil?
      # @undo_buffer.unshift(thing)
    else
      thing = model.create!(attributes)
      save_for_undo(thing)
    end
    thing
  end

  def default_attributes(model)
    {
      Inventory::Part => {
        part_category: Inventory::PartCategory.find_by(name: 'Asurion'),
        serialized: false,
        active: true,
        part_type: Inventory::PartType.find_by(name: :equipment),
        ir_price_available: false,
        returnable: true
      },
      Payroll::InvoiceItem => {
        invoice_item_type: Payroll::InvoiceItemType.find_by(name: 'Equipment')
      },
      Payroll::InvoiceItemPart => {
      },
      Dispatching::ServiceCode => {
        service_code_type: Dispatching::ServiceCodeType.find_by(name: :payroll),
        rank: 0,
        active: true,
        smart_home: false,
        chargeback: true
      },
      Payroll::InvoiceItemServiceCode => {
      }
    }[model]
  end

  def save_for_undo(thing)
    @undo_buffer.unshift(thing)
    nil
  end

  def collect_created_items(data)
    @created_items << data
    nil
  end

  def debugging
    @debugging = !@debugging
  end

  def show(indent, text)
    prefix = text[0] * (indent - 1)
    puts "#{prefix}#{text}"
  end

  def debug(indent, text)
    return unless @debugging
    show(indent, text)
  end
end

def set_it_all_up
  provider = 'Asurion'
  file = 'sc-audit/asurion-service-codes.csv'

  loader = MyLoader.new(file: file)
  puts 'loader instantiated'
  @items = loader.data
  puts "#{@items.count} items loaded into @items from '#{file}'"
  @builder = MyBuilder.new(provider: provider)
  puts 'builder instantiated as @builder'
end

def do_it_all
  @items.each do |item|
    @builder.create_stuff(item['number'], item['cost'])
  end

  @builder.set_amounts
end

def undo_it_all
  @builder.undo
end