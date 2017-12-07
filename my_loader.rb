#
# MyLoader
#  Loads service code name and attributes, including cost data, from a .CSV
#  file.  It expects to see multiple records differing only by cost and will
#  load only the record that has the highest cost data.
#
#  - The object is Enumerable and can be treated like a R/O array of service code attribute hashes.
#    Whatever columns are in the .CSV will be in the attributes.
#
class MyLoader
  include Enumerable

  attr_reader :data, :provider

  def initialize(file: 'sc-audit/asurion-service-codes.csv')
    @data = get_max_pricedata_from_file(file)
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
