module Orocos
    module Async
        module ROS
            # Async access for the ROS name service
            class NameService < Orocos::Async::RemoteNameService
                def initialize(uri = ENV['ROS_MASTER_URI'], caller_id = Orocos::ROS.caller_id, options = Hash.new)
                    name_service = Orocos::ROS::NameService.new(uri, caller_id)
                    super(name_service, options)
                end

                # add methods which forward the call to the underlying task context
                forward_to :@delegator_obj,:@event_loop, :known_errors => [Orocos::ComError,Orocos::NotFound],:on_error => :emit_error do
                    methods = Orocos::ROS::NameService.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
                    methods -= Orocos::Async::ROS::NameService.instance_methods + [:method_missing]
                    def_delegators methods
                end
            end

            # Async access to ROS nodes
            class Node < Orocos::Async::TaskContextBase
                def initialize(name_service, server, name, options = Hash.new)
                    super(name, options.merge(:name_service => name_service, :server => server, :name => name))
                end

                def configure_delegation(options)
                    options = Kernel.validate_options options,
                        :name_service, :server, :name

                    @name_service, @server, @name =
                        if !valid_delegator?
                            [options[:name_service], options[:server], options[:name]]
                        else
                            [@delegator_obj.name_service, @delegator_obj.server, @delegator_obj.name]
                        end
                    if !@name_service || !@server || !@name
                        raise ArgumentError, "cannot resolve a proper name_service/ROS master/name tuple"
                    end
                end

                def access_remote_task_context
                    node = Orocos::ROS::Node.new(@name_service, @server, @name)
                    [node, name]
                end

                # add methods which forward the call to the underlying task context
                forward_to :task_context,:@event_loop, :known_errors => [Orocos::ComError,Orocos::NotFound],:on_error => :emit_error do
                    methods = Orocos::ROS::Node.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
                    methods -= Orocos::Async::ROS::Node.instance_methods + [:method_missing]
                    def_delegators methods
                end
            end
        end
    end
end

