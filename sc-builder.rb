class ServiceCodeBuilder
  attr_reader :data

  def initialize(file_name: 'asurion-service-codes.csv', provider_name: 'Asurion')
    @provider = Dispatching::ServiceProvider.find_by(name: provider_name)
    raise "?service_provider_name not found in Dispatching::ServiceProvider table!" if @provider.nil?

    @data = curated_data_from_file(file_name)
    self
  end

  def create_service_codes
    @data.each do |codename, _|
      Dispatching::ServiceCode.create!(sc_attributes(codename))
    end
  end

  def create_provider_service_code_maps
    @data.each do |codename, _|
      if mapping_exists?(codename)
        puts "??? Provider Service Code Map exists for #{codename}" if mapping_exists?(codename)
      else
        Dispatching::ServiceProviderServiceCodeMap.new(
          service_provider: @provider,
          external_code: codename,
          service_code: Dispatching::ServiceCode.find_by(short_name: codename),
          sticky: false)
      end
    end
  end

  def delete_service_codes
    @data.each do |codename, _|
      sc = Dispatching::ServiceCode.find_by(description: codename)
      if sc.present?
        sc.destroy!
      else
        puts "??? #{codename}: no Dispatching::ServiceCode record found to destroy"
      end
    end
  end

  def delete_provider_service_code_maps
    @data.each do |codename, _|
      scm = Dispatching::ServiceProviderServiceCodeMap.find_by(external_code: codename)
      if scm.present?
        scm.destroy!
      else
        puts "??? #{codename}: no Dispatching::ServiceProviderServiceCode record found to destroy"
      end
    end
  end

  private

  def mapping_exists?(codename)
    sc = Dispatching::ServiceCode.find_by(short_name: codename)
    return false if sc.nil?

    scm = Dispatching::ServiceProviderServiceCodeMap.find_by(
      external_code: codename,
      service_code: sc)
    scm
  end

  def sc_attributes(codename)
    {
      description: codename,
      service_code_type: type_code,
      short_name: codename,
      rank: 0,
      active: true,
      smart_home: false,
      chargeback: true
    }
  end

  def type_code
    @type_code ||= Dispatching::ServiceCodeType.find_by(name: :payroll)
  end

  def curated_data_from_file(file_name)
    raw_data = CSV.read(file_name, headers: true).map { |line| line.to_h }
    curated_data = {}
    raw_data.each do |item|
      code = item['number']
      curated_data[code] ||= item
      curated_data[code] = item if curated_data[code]['cost'] < item['cost']
    end
    curated_data.sort.to_h
  end
end
