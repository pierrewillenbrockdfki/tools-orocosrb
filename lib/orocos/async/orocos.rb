module Orocos
    module Log
        class OutputPort
            def to_async(options = Hash.new)
                self.tracked = true
                task.to_async(options).port(name,:type => type).wait
            end

            def to_proxy(options = Hash.new)
                self.tracked = true
                task.to_proxy(options).port(name,:type => type).wait
            end
        end

        class TaskContext
            def to_async(options = Hash.new)
                Orocos::Async::Log::TaskContext.new(self,options)
            end

            def to_proxy(options = Hash.new)
                log_replay.name_service_async.proxy(name,:use => to_async).wait
            end
        end
    end

    class Attribute
        def to_async(options = Hash.new)
            if use = options.delete(:use)
                Orocos::Async::CORBA::Attribute.new(use,self,options)
            else to_async(Hash[:use => task.to_async].merge(options))
            end
        end

        def to_proxy(options = Hash.new)
            task.to_proxy(options).attribute(name,:type => type)
        end
    end

    class Property
        def to_async(options = Hash.new)
            if use = options.delete(:use)
                Orocos::Async::CORBA::Property.new(use,self,options)
            else to_async(Hash[:use => task.to_async].merge(options))
            end
        end

        def to_proxy(options = Hash.new)
            task.to_proxy(options).property(name,:type => type)
        end
    end

    class InputPort
        def to_async(options = Hash.new)
            if use = options.delete(:use)
                Orocos::Async::CORBA::InputPort.new(use,self,options)
            else to_async(Hash[:use => task.to_async].merge(options))
            end
        end

        def to_proxy(options = Hash.new)
            task.to_proxy(options).port(name,:type => type)
        end
    end

    class OutputPort
        def to_async(options = Hash.new)
            if use = options.delete(:use)
                Orocos::Async::CORBA::OutputPort.new(use,self,options)
            else to_async(Hash[:use => task.to_async].merge(options))
            end
        end

        def to_proxy(options = Hash.new)
            task.to_proxy(options).port(name,:type => type)
        end
    end

    class TaskContext
        def to_async(options = Hash.new)
            options[:name] ||= name
            options[:ior] ||= ior
            Orocos::Async::CORBA::TaskContext.new(options.merge(use: self))
        end

        def to_proxy(options = Hash.new)
            options[:use] ||= to_async
            # use name service to check if there is already
            # a proxy for the task
            Orocos::Async.proxy(name,options)
        end
    end
end

