load 'sc-audit/my_loader.rb'
load 'sc-audit/my_builder.rb'

def set_it_all_up
  provider = 'Asurion'
  file = 'sc-audit/asurion-service-codes.csv'

  @items = MyLoader.new(file: file)
  puts "loader instantiated as @items and #{@items.count} items loaded from '#{file}'"

  @builder = MyBuilder.new(provider: provider, type: 'Payroll');nil
  puts 'builder instantiated as @builder'
end

def do_it_all
  @items.each do |item|
    @builder.create_stuff(item['number'], item['type'], item['cost'])
  end

  @builder.set_amounts
  @builder.undo_buffer_entries
end

def undo_it_all
  @builder.undo
end

puts "defined methods: set_it_all_up, do_it_all, undo_it_all"
