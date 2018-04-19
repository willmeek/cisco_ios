require 'puppet_x'

module PuppetX::CiscoIOS
  # Helper functions for the Cisco IOS module
  class Utility
    def self.load_yaml(full_path, replace_double_escapes = true)
      raise "File #{full_path} doesn't exist." unless File.exist?(full_path)
      yaml_file = File.read(full_path)
      data_hash = YAML.safe_load(yaml_file, [Symbol])
      data_hash = replace_double_escapes(data_hash) if replace_double_escapes
      data_hash
    end

    def self.replace_double_escapes(data_hash)
      data_hash.each_pair do |key, value|
        if value.is_a?(Hash)
          replace_double_escapes(value)
        elsif value.is_a?(String)
          data_hash[key] = value.gsub(%r{\\\\}, '\\')
        end
      end
      data_hash
    end

    def self.version_match_ok
      true
    end

    # Return false if the device is on the exclusion list
    # True otherwise
    def self.device_match_ok(exclusion_hash)
      exclusion_hash.each do |exclusion|
        next if exclusion['device'].nil?
        next unless PuppetX::CiscoIOS::Utility.ios_device_type =~ %r{#{exclusion['device']}}
        return false
      end
      true
    end

    def self.safe_to_run(exclusion_hash)
      # TODO: iterate over the exclusion entries, if any exclusion matched it is not safe and break.
      version_match_ok && device_match_ok(exclusion_hash)
    end

    def self.ios_device_type
      facts = Puppet::Util::NetworkDevice::Cisco_ios::Device.transport.facts
      unless facts.nil?
        return facts['hardwaremodel']
      end
      'default'
    end

    def self.parent_device(commands_hash)
      device_type = PuppetX::CiscoIOS::Utility.ios_device_type
      if commands_hash[device_type].nil?
        'default'
      else
        # else use device specific yaml
        device_type
      end
    end

    def self.get_interface_names(command_hash)
      parent_device = parent_device(command_hash)
      return_val = command_hash['get_interfaces_command'][parent_device]
      # TODO: error check that the attribute exists in the yaml
      return_val
    end

    def self.get_values(command_hash)
      parent_device = parent_device(command_hash)
      return_val = command_hash['get_values'][parent_device]
      # TODO: error check that the attribute exists in the yaml
      return_val
    end

    def self.get_instances(command_hash)
      parent_device = parent_device(command_hash)
      return_val = command_hash['get_instances'][parent_device]
      # TODO: error check that the attribute exists in the yaml
      return_val
    end

    def self.parse_resource(output, command_hash)
      attributes_hash = {}
      command_hash['attributes'].each do |attribute|
        value = parse_attribute(output, command_hash, attribute.first)
        attributes_hash[attribute.first.to_sym] = value
      end
      attributes_hash
    end

    def self.attribute_safe_to_run(command_hash, attribute)
      attribute_device = parent_device(command_hash)
      exclusions = command_hash['attributes'][attribute]['exclusions']
      attribute_is_empty = command_hash['attributes'][attribute][attribute_device].nil?
      if !exclusions.nil? && (!safe_to_run(exclusions) || attribute_is_empty)
        Puppet.debug "This attribute '#{attribute}', is not available for this device "\
                     "'#{Puppet::Util::NetworkDevice::Cisco_ios::Device.transport.facts['hardwaremodel']}' "\
                     "and/or version '#{Puppet::Util::NetworkDevice::Cisco_ios::Device.transport.facts['operatingsystemrelease']}'"
        return false
      end
      true
    end

    def self.parse_attribute(output, command_hash, attribute)
      # Is there a whole new device in the yaml at the top level
      # eg
      # ---
      # default:
      #  ...
      # nxos:  <---- this is a device specific implementation
      # is there an device version of the attribute

      unless attribute_safe_to_run(command_hash, attribute)
        return
      end

      attribute_device = parent_device(command_hash)
      default_value = command_hash['attributes'][attribute][attribute_device]['default']
      can_have_no_match = command_hash['attributes'][attribute][attribute_device]['can_have_no_match']
      regex = command_hash['attributes'][attribute][attribute_device]['get_value']
      if regex.nil?
        Puppet.debug "Missing key/pair in yaml file for '#{attribute}'.\nExpects:->attributes:->#{attribute}:->#{attribute_device}:->get_value: 'regex here'"
        returned_value = []
      else
        returned_value = output.scan(%r{#{regex}})
      end
      if returned_value.empty?
        # there is no match
        if !can_have_no_match.nil?
          # it is ok for this attribute to return nil
          returny = nil
        elsif !default_value.nil?
          # use the default value
          returny = default_value
        else
          Puppet.debug "Regex for attribute '#{attribute}' failed"
        end
      elsif returned_value.size == 1
        # there is a single match
        returny = returned_value.flatten.first
      else
        # we have an array of matches.
        returny = returned_value.flatten
      end
      returny
    end

    # build a single command_line from attributes
    def self.set_values(instance, command_hash)
      parent_device = parent_device(command_hash)
      command_line = command_hash['set_values'][parent_device]
      # Set the state, of the commandline eg 'no ntp server
      if !command_hash['ensure_is_state'].nil? && command_hash['ensure_is_state'][parent_device]
        command_line = if instance[:ensure] == 'present'
                         command_line.to_s.gsub(%r{<state>}, '')
                       else
                         command_line.to_s.gsub(%r{<state>}, 'no')
                       end
      end
      instance.each do |key, value|
        # if print_key exists then print the key, otherwise dont
        print_key = if key == :ensure
                      false
                    else
                      # if print_key exists then print the key, otherwise dont
                      !command_hash['attributes'][key.to_s][parent_device]['print_key'].nil?
                    end
        command_line = insert_attribute_into_command_line(command_line, key, value, print_key) if key == :ensure || PuppetX::CiscoIOS::Utility.attribute_safe_to_run(command_hash, key.to_s)
      end
      command_line = command_line.to_s.gsub(%r{<\S*>}, '')
      command_line = command_line.squeeze(' ')
      command_line = command_line.strip
      # TODO: if there is anything that looks like this <.*> it is probably a bug
      command_line
    end

    def self.build_commmands_from_attribute_set_values(instance, command_hash)
      command_lines = []
      parent_device = parent_device(command_hash)
      instance.each do |key, value|
        if key != :ensure && !command_hash['attributes'][key.to_s]['exclusions'].nil?
          next unless safe_to_run(command_hash['attributes'][key.to_s]['exclusions'])
        end

        command_line = ''
        # if print_key exists then print the key, otherwise dont
        print_key = false
        if value == 'unset'
          command_line = command_hash['attributes'][key.to_s][parent_device]['unset_value']
        elsif key != :ensure
          command_line = command_hash['attributes'][key.to_s][parent_device]['set_value']
          # if print_key exists then print the key, otherwise dont
          print_key = !command_hash['attributes'][key.to_s][parent_device]['print_key'].nil?
        end
        command_line = insert_attribute_into_command_line(command_line, key, value, print_key)
        command_line = command_line.to_s.gsub(%r{<\S*>}, '')
        command_line = command_line.squeeze(' ')
        command_line = command_line.strip
        command_lines << command_line if command_line != ''
      end
      command_lines
    end

    def self.insert_attribute_into_command_line(command_line, key, value, print_key)
      command_line = if value.nil?
                       # no value so remove the key from the command_line
                       command_line.to_s.gsub(%r{<#{key}>}, '')
                     elsif print_key
                       command_line.to_s.gsub(%r{<#{key}>}, value ? "#{key} #{value}" : '')
                     else
                       command_line.to_s.gsub(%r{<#{key}>}, value ? value.to_s : '')
                     end
      command_line
    end

    def self.detect_ipv4_or_ipv6(address)
      # Is it IPv4?
      return "ipv4 #{address}" if address =~ Resolv::IPv4::Regex
      # Is it IPv6?
      return "ipv6 #{address}" if address =~ Resolv::IPv6::Regex
      # Some other type of hostname that is neither IPv4 or IPv6, just return
      address
    end

    def self.convert_no_to_boolean(value)
      return_value = if value.nil?
                       true
                     else
                       false
                     end
      return_value
    end

    def self.convert_enable_to_string(enable_value)
      return_value = if enable_value == false
                       'no'
                     else
                       ''
                     end
      return_value
    end

    def self.convert_level_name_to_int(level_enum)
      level = if level_enum == 'debugging'
                7
              elsif level_enum == 'informational'
                6
              elsif level_enum == 'notifications'
                5
              elsif level_enum == 'warnings'
                4
              elsif level_enum == 'errors'
                3
              elsif level_enum == 'critical'
                2
              elsif level_enum == 'alerts'
                1
              elsif level_enum == 'emergencies'
                0
              else
                raise "Cannot convert logging level '#{level_enum}' to an integer."
              end
      level
    end

    def self.convert_level_int_to_name(level)
      level_enum = if level == 7
                     'debugging'
                   elsif level == 6
                     'informational'
                   elsif level == 5
                     'notifications'
                   elsif level == 4
                     'warnings'
                   elsif level == 3
                     'errors'
                   elsif level == 2
                     'critical'
                   elsif level == 1
                     'alerts'
                   elsif level.zero?
                     'emergencies'
                   else
                     raise "Cannot convert logging name '#{level}' to an named level"
                   end
      level_enum
    end

    def self.convert_speed_int_to_modelled_value(speed_value)
      speed = if speed_value == '10'
                '10m'
              elsif speed_value == '100'
                '100m'
              elsif speed_value == '1000'
                '1g'
              else
                speed_value
              end
      speed
    end

    def self.convert_modelled_speed_value_to_int(speed_value)
      speed_value = if speed_value == '10m'
                      '10'
                    elsif speed_value == '100m'
                      '100'
                    elsif speed_value == '1g'
                      '1000'
                    else
                      speed_value
                    end
      speed_value
    end

    def self.convert_source_interface(commands_hash, should, parent_device)
      if should[:source_interface]
        set_command_source = commands_hash['attributes']['source_interface'][parent_device]['set_value']
        set_command_source = set_command_source.gsub(%r{<source_interface>},
                                                     (should[:source_interface] == 'unset') ? '' : should[:source_interface])
        set_command_source = set_command_source.gsub(%r{<state>},
                                                     (should[:source_interface] == 'unset') ? 'no ' : '')
      else
        set_command_source = ''
      end
      set_command_source
    end

    def self.convert_tacacs_server_group_servers(commands_hash, is, should, parent_device)
      should_servers = []
      unless should[:servers].nil?
        should_servers = should[:servers].split(',')
      end

      is_servers = []
      unless is.nil? || is[:servers].nil?
        is_servers = is[:servers].split(',')
      end

      new_servers =  should_servers - is_servers
      remove_servers = is_servers - should_servers

      array_of_servers = []

      new_servers.each do |new_server|
        set_new_server = commands_hash['attributes']['servers'][parent_device]['set_value']
        set_new_server = set_new_server.gsub(%r{<state>}, '')
        set_new_server = set_new_server.gsub(%r{<server>}, new_server)
        array_of_servers.push(set_new_server)
      end

      remove_servers.each do |remove_server|
        set_remove_server = commands_hash['attributes']['servers'][parent_device]['set_value']
        set_remove_server = set_remove_server.gsub(%r{<state>}, 'no ')
        set_remove_server = set_remove_server.gsub(%r{<server>}, remove_server)
        array_of_servers.push(set_remove_server)
      end
      array_of_servers
    end

    def self.commands_from_diff_of_two_arrays(commands_hash, is, should, parent_device, attribute)
      is = [] if is.nil?
      should = [] if should.nil?

      new_entities =  should - is
      remove_entities = is - should

      array_of_commands = []

      new_entities.each do |new_entity|
        add_command = commands_hash['attributes'][attribute][parent_device]['set_value']
        add_command = add_command.gsub(%r{<#{attribute}>}, new_entity.to_s).strip
        array_of_commands.push(add_command)
      end

      remove_entities.each do |remove_entity|
        remove_command = commands_hash['attributes'][attribute][parent_device]['unset_value']
        remove_command = remove_command.gsub(%r{<#{attribute}>}, remove_entity.to_s)
        array_of_commands.push(remove_command)
      end
      array_of_commands
    end

    def self.convert_vlan_absent(commands_hash, should, parent_device)
      set_command_vlan_absent = commands_hash['attributes']['ensure'][parent_device]['set_value']
      set_command_vlan_absent = set_command_vlan_absent.to_s.gsub(%r{<state>}, 'no ')
      set_command_vlan_absent = set_command_vlan_absent.to_s.gsub(%r{<name>}, (should[:name]).to_s)
      set_command_vlan_absent
    end

    def self.convert_vlan_name(commands_hash, value, parent_device)
      set_command_vlan_name = commands_hash['attributes']['vlan_name'][parent_device]['set_value']
      set_command_vlan_name = set_command_vlan_name.to_s.gsub(%r{<vlan_name>}, value.to_s)
      set_command_vlan_name = if value.to_s == 'unset'
                                set_command_vlan_name.to_s.gsub(%r{<state>}, 'no ')
                              else
                                set_command_vlan_name.to_s.gsub(%r{<state>}, '')
                              end
      set_command_vlan_name
    end

    def self.convert_vlan_shutdown(commands_hash, value, parent_device)
      set_command_vlan_shutdown = commands_hash['attributes']['shutdown'][parent_device]['set_value']
      set_command_vlan_shutdown = if value.to_s == 'false'
                                    set_command_vlan_shutdown.to_s.gsub(%r{<state>}, 'no ')
                                  else
                                    set_command_vlan_shutdown.to_s.gsub(%r{<state>}, '')
                                  end
      set_command_vlan_shutdown = set_command_vlan_shutdown.to_s.gsub(%r{<shutdown>}, value.to_s)
      set_command_vlan_shutdown
    end

    def self.network_snmp_enable_false(commands_hash)
      enable_false_commands = []
      attribute_device = parent_device(commands_hash)
      contact_command = commands_hash['enable_false'][attribute_device]
      enable_false_commands.push(contact_command)
      enable_false_commands
    end

    def self.convert_network_trunk_mode_cli(trunk_mode_output)
      if trunk_mode_output == 'dynamic auto'
        trunk_mode_output = 'dynamic_auto'
      elsif trunk_mode_output == 'dynamic desirable'
        trunk_mode_output = 'dynamic_desirable'
      elsif trunk_mode_output == 'static access'
        trunk_mode_output = 'access'
      end
      trunk_mode_output
    end

    def self.convert_network_trunk_mode_modelled(trunk_mode_output)
      if trunk_mode_output == 'dynamic_auto'
        trunk_mode_output = 'dynamic auto'
      elsif trunk_mode_output == 'dynamic_desirable'
        trunk_mode_output = 'dynamic desirable'
      end
      trunk_mode_output
    end
  end
end
