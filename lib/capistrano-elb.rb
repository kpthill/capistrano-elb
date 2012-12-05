require 'fog'
require 'yaml'
require 'capistrano'
require 'pp'

class Hash
  def diff(h2)
    dup.delete_if { |k, v| h2[k] == v }.merge!(h2.dup.delete_if { |k, v| has_key?(k) })
  end
end

class CapELB
  def initialize(configdir=File.join(Dir.pwd, 'config'))
    ec2credentials = YAML::load(File.open(File.join(configdir, 'ec2credentials.yaml')))
    aws = Fog::Compute.new(ec2credentials.merge({:provider=>'AWS'}))
    @regions = aws.describe_regions.body["regionInfo"].map {|region| region["regionName"]}
    @compute = {}
    @regions.each do |region|
      @compute.merge!(region => Fog::Compute.new(ec2credentials.merge({:provider=>'AWS',:region=>region})))
    end

    @elb = {}
    @regions.each do |region|
      @elb.merge!(region => Fog::AWS::ELB.new(ec2credentials.merge(:region=>region)))
    end

    @lbs = config_from_lb
  end

  def config_from_tags
    lbs = {}
    @regions.each do |region|
      @elb[region].load_balancers.each do |lb|
        lbs[region] = {} unless lbs[region].is_a?(Hash)
        lbs[region].merge!({lb.id => get_instances(region,lb.id)})
      end
    end
    lbs
  end

  def config_from_lb
    lbs = {}
    @regions.each do |region|
      @elb[region].load_balancers.each do |lb|
        lbs[region] = {} unless lbs[region].is_a?(Hash)
        lbs[region].merge!({lb.id => lb.instances})
      end
    end
    lbs
  end

  def get_instances(region,lbname)
    @compute[region].tags.select{|tag| tag.key == 'elb' and tag.value==lbname}.map(&:resource_id)
  end

  def check_config
    pp @lbs
    current = config_from_lb
    errors = []
    @lbs.each_pair do |region,lbs|
      lbs.each_pair do |lbname, target_instances|
        missing = target_instances - current[region][lbname]
        extra = current[region][lbname] - target_instances
        errors << "#{missing} are missing from #{region}/#{lbname}" unless missing.empty?
        errors << "#{extra} should not be in #{region}/#{lbname}" unless extra.empty?
      end
    end
    (errors.empty? ? "ELB config correct" : errors)
  end

  def add(serverlist)
    @lbs.each_pair do |region, lbs|
      lbs.each_pair do |lbname, target_instances|
        server_ids = @compute[region].servers.select{|server| serverlist.include? server.dns_name}.map{|server| server.id}
        to_change = server_ids.select{|server_id| target_instances.include? server_id}
        unless to_change.empty?
          puts "Adding #{to_change} to LB #{lbname} in #{region}"
          @elb[region].register_instances_with_load_balancer(to_change, lbname)
        end
      end
    end
  end

  def remove(serverlist)
    @lbs.each_pair do |region, lbs|
      lbs.each_pair do |lbname, target_instances|
        server_ids = @compute[region].servers.select{|server| serverlist.include? server.dns_name}.map{|server| server.id}
        to_change = server_ids.select{|server_id| target_instances.include? server_id}
        unless to_change.empty?
          puts "Removing #{to_change} from LB #{lbname} in #{region}"
          @elb[region].deregister_instances_from_load_balancer(to_change, lbname)
        end
      end
    end
  end
end
