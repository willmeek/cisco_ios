require 'puppet/resource_api'
require 'puppet/resource_api/simple_provider'
require 'puppet/util/network_device/cisco_ios/device'
require 'puppet_x/puppetlabs/cisco_ios/utility'
require 'pry'

# Network SNMP Puppet Provider for Cisco IOS devices
class Puppet::Provider::NetworkSnmp::NetworkSnmp < Puppet::ResourceApi::SimpleProvider
  def self.commands_hash
    @commands_hash = PuppetX::CiscoIOS::Utility.load_yaml(File.expand_path(__dir__) + '/command.yaml')
  end

  def self.instances_from_cli(output)
    new_instance_fields = []
    new_instance = PuppetX::CiscoIOS::Utility.parse_resource(output, commands_hash)
    new_instance[:enable] = if !output.scan(%r{#{PuppetX::CiscoIOS::Utility.get_instances(@commands_hash)}}).empty?
                              true
                            else
                              false
                            end
    new_instance[:name] = 'default'
    new_instance[:ensure] = (new_instance[:contact] || new_instance[:location]) ? :present : :absent
    new_instance.delete_if { |_k, v| v.nil? }
    new_instance_fields << new_instance
    new_instance_fields
  end

  def self.command_from_instance(property_hash)
    if property_hash[:ensure] == :absent
      return PuppetX::CiscoIOS::Utility.network_snmp_absent(commands_hash)
    end
    if property_hash[:enable] == false
      return PuppetX::CiscoIOS::Utility.network_snmp_enable_false(commands_hash)
    end
    PuppetX::CiscoIOS::Utility.build_commmands_from_attribute_set_values(property_hash, commands_hash)
  end

  def commands_hash
    Puppet::Provider::NetworkSnmp::NetworkSnmp.commands_hash
  end

  def get(_context)
    output = Puppet::Util::NetworkDevice::Cisco_ios::Device.run_command_enable_mode(PuppetX::CiscoIOS::Utility.get_values(commands_hash))
    return [] if output.nil?
    Puppet::Provider::NetworkSnmp::NetworkSnmp.instances_from_cli(output)
  end

  def create(_context, _name, should)
    array_of_commands_to_run = Puppet::Provider::NetworkSnmp::NetworkSnmp.command_from_instance(should)
    array_of_commands_to_run.each do |command|
      Puppet::Util::NetworkDevice::Cisco_ios::Device.run_command_conf_t_mode(command)
    end
  end

  alias update create

  def delete(_context, name)
    clear_hash = { name: name, ensure: :absent }
    array_of_commands_to_run = Puppet::Provider::NetworkSnmp::NetworkSnmp.command_from_instance(clear_hash)
    array_of_commands_to_run.each do |command|
      Puppet::Util::NetworkDevice::Cisco_ios::Device.run_command_conf_t_mode(command)
    end
  end
end