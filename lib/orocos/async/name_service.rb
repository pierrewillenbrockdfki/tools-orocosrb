module Orocos::Async

    # Returns the global async name service abstracting all underlying name services.
    # This should be the default way to acquire an handle to an Orocos Task by
    # its name. If the IOR of the task is already known {Async::TaskContext} should
    # directly be used.
    def self.name_service
        @name_service ||= Orocos::Async::NameService.new()
    end

    def self.name_service=(name_service)
        @name_service = nil
    end

    # (see NameService#get)
    def self.get(name,options =Hash.new)
        name_service.get(name,options)
    end

    def self.proxy(name,options = Hash.new)
        name_service.proxy(name,options)
    end

    class NameServiceBase < ObjectBase
        extend Utilrb::EventLoop::Forwardable
        extend Orocos::Async::ObjectBase::Periodic::ClassMethods
        include Orocos::Async::ObjectBase::Periodic
        include Orocos::Namespace

        # @!method on_task_added
        #
        # Registers an event callback that will receive new task names when the
        # name service reports them
        #
        # @yieldparam [String] name use {#proxy} to resolve it into a task
        #   context proxy
        # @return [void]
        define_events :task_added
        
        # @!method on_task_added
        #
        # Registers an event callback that will receive task names when the task
        # got deregistered from the name service(s)
        #
        # @yieldparam [String] name
        # @return [void]
        define_events :task_removed

        attr_reader :task_context_proxies

        self.default_period = 1.0

        def initialize(name_service,options = Hash.new)
            @options ||= Kernel.validate_options options,:period => default_period,:start => false,:sync_key => nil,:known_errors => Orocos::Async::KNOWN_ERRORS,:event_loop => Orocos::Async.event_loop
            @stored_names ||= Set.new
            _,options_async = Kernel.filter_options @options,:event_loop=>nil
            super(name_service.name,@options[:event_loop])
            disable_emitting do
                reachable! name_service
            end
            @watchdog_timer = @event_loop.async_every method(:names),options_async do |names|
                names.each do |name|
                    n = @stored_names.add? name
                    event :task_added,name if n
                end
                @stored_names.delete_if do |name|
                    if !names.include?(name)
                        event :task_removed,name
                        true
                    else
                        false
                    end
                end
            end
            @watchdog_timer.doc = name
            @task_context_proxies = Array.new
        end

        def really_add_listener(listener)
            if listener.event == :task_added || listener.event == :task_removed 
                @watchdog_timer.start unless @watchdog_timer.running?
                if listener.use_last_value? && !@stored_names.empty?
                    @stored_names.each do |name|
                        listener.call name
                    end
                end
            end
            super
        end

        def remove_listener(listener)
            super
            if number_of_listeners(:task_removed) == 0 && number_of_listeners(:task_added) == 0
                @watchdog_timer.cancel
                @stored_names.clear
            end
        end

        def proxy(name,options = Hash.new)
            name = if name.respond_to?(:name)
                       name.name
                   else
                       name
                   end
            options[:event_loop] ||= @event_loop
            options[:name_service] ||= self
            ns,base_name = split_name(name)
            ns ||= ""
            task = @task_context_proxies.find do |t|
                ns2,base_name2= split_name(t.name)
                ns2 ||= ""
                ns == ns2 && base_name == base_name2 && t.event_loop == options[:event_loop] && t.name_service == options[:name_service]
            end
            if task
                options.each_pair do |key,value|
                    if task.options[key] != value
                        # TODO add proper pretty_print methods to display options otherwise console will be flooded
                        Orocos.warn "TaskContextProxy #{name} is already initialized with different options."
                       # Orocos.warn "Ignoring options: #{options}."
                        break
                    end
                end
                task
            else
                @task_context_proxies << Orocos::Async::TaskContextProxy.new(name,options)
                @task_context_proxies.last
            end
        end
    end

    class NameService < NameServiceBase
        define_events :name_service_added, :name_service_removed

        def initialize(*name_services)
            options = if name_services.last.is_a? Hash
                          name_services.pop
                      else
                          Hash.new
                      end
            name_services = name_services.map { |ns| ns.to_async }
            name_service = Orocos::NameService.new *name_services
            super(name_service,options)
        end

        def clear
            task_context_proxies.clear
            orig_clear
        end

        def proxy(name,options = Hash.new)
            if(name_services.empty?)
                Vizkit.error "Orocos is not initialized!" unless Orocos.initialized?
                raise "No name service available."
            end
            super
        end

        # Overloaded to emit the name_service_added event for already registered
        # name services
        def add_listener(listener)
            if listener.event == :name_service_added
                services = name_services.dup
                event_loop.once do
                    services.each do |ns|
                        listener.call ns
                    end
                end
            end
            super
        end

        # (see Orocos::NameServiceBase#add)
        #
        # Emits the name_service_added event
        def add(name_service)
            name_service = name_service.to_async
            orig_add(name_service)
            event :name_service_added,name_service
        end

        # (see Orocos::NameServiceBase#add_front)
        #
        # Emits the name_service_added event
        def add_front(name_service)
            name_service = name_service.to_async
            orig_add_front(name_service)
            event :name_service_added,name_service
        end

        # (see Orocos::NameServiceBase#remove)
        #
        # Emits the name_service_removed event
        def remove(name_service)
            removed = false
            name_services.delete_if do |ns|
                if name_service == ns || ns.delegator_obj == ns
                    true
                end
            end
            if removed
                event :name_service_removed,name_service
                true
            end
        end

        private
        # add methods which forward the call to the underlying name service
        forward_to :@delegator_obj,:@event_loop, :known_errors => Orocos::Async::KNOWN_ERRORS do
            methods = Orocos::NameService.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::NameService.instance_methods + [:method_missing]
            def_delegator :add,:alias => :orig_add
            def_delegator :add_front,:alias => :orig_add_front
            def_delegator :clear,:alias => :orig_clear
            def_delegators methods
        end
    end

    module Local
        class NameService < NameServiceBase
            extend Utilrb::EventLoop::Forwardable

            def initialize(options = Hash.new)
                options,other_options = Kernel.filter_options options,
                    :tasks => Array.new

                name_service = Orocos::Local::NameService.new options[:tasks]
                super(name_service,other_options)
            end

            def get(name,options=Hash.new,&block)
                async_options,other_options = Kernel.filter_options options,
                    :sync_key => nil,
                    :raise => nil,
                    :event_loop => @event_loop,
                    :period => nil,
                    :wait => nil

                if block
                    p = proc do |task,error|
                        task = task.to_async(async_options) unless error
                        if block.arity == 2
                            block.call task,error
                        elsif !error
                            block.call task
                        end
                    end
                    orig_get name,**other_options,&p
                else
                    task = orig_get name,**other_options
                    task.to_async(async_options)
                end
            end

            private
            # add methods which forward the call to the underlying name service
            forward_to :@delegator_obj,:@event_loop,:known_errors=> Orocos::Async::KNOWN_ERRORS do
                methods = Orocos::Local::NameService.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
                methods -= Orocos::Async::Local::NameService.instance_methods + [:method_missing]
                def_delegators methods
                def_delegator :get,:alias => :orig_get
            end
        end
    end

    # Base class for name services that are accessed remotely (e.g. over the
    # network)
    class RemoteNameService < NameServiceBase
        extend Utilrb::EventLoop::Forwardable

        def initialize(name_service,options = Hash.new)
            options = Kernel.validate_options options,
                :reconnect => true,
                :known_errors => Array.new
            
            @reconnect = options.delete(:reconnect)
            options[:known_errors].concat([Orocos::ComError,Orocos::NotFound])
            super(name_service,options)
            @namespace = name_service.namespace
        end

        # True if this name service should automatically reconnect
        # @return [Boolean]
        def reconnect?; @reconnect end

        def unreachable!(options = Hash.new)
            @watchdog_timer.stop
            if !valid_delegator?
                raise "This should never happen. There must be always a valid delegator obj"
            end

            if reconnect? && options.has_key?(:error)
                obj = @delegator_obj
                obj.reset
                timer = @event_loop.async_every obj.method(:names),:period => 1.0,:sync_key => nil,:known_errors => [Orocos::NotFound,Orocos::ComError] do |names,error|
                    if error
                        obj.reset
                    else
                        reachable!(obj)
                        @watchdog_timer.start
                        timer.stop
                    end
                end
                timer.doc = "NameService #{name} reconnect"
            else
            end
            super
        end

        def name
            @delegator_obj.name
        end

        def get(name,options=Hash.new,&block)
            async_options,other_options = Kernel.filter_options options, 
                :sync_key => nil,:raise => nil,:event_loop => @event_loop,
                :period => nil,:wait => nil

            if block
                p = proc do |task,error|
                    async_options[:use] = task
                    atask = if !error
                                task.to_async(async_options)
                            end
                    if block.arity == 2
                        block.call atask,error
                    elsif !error
                        block.call atask
                    end
                end 
                orig_get name,**other_options,&p
            else
                task = orig_get name,**other_options
                task.to_async(Hash[:use => task].merge(async_options))
            end
        end

        private
        # add methods which forward the call to the underlying name service
        forward_to :@delegator_obj,:@event_loop, :known_errors => [Orocos::ComError,Orocos::NotFound], :on_error => :error do
            methods = Orocos::NameServiceBase.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::RemoteNameService.instance_methods + [:method_missing]
            thread_safe do 
                def_delegators methods
                def_delegator :get,:alias => :orig_get
            end
        end

        def error(e)
            emit_error e if !e.is_a? Orocos::NotFound
        end
    end

    module CORBA
        class << self
            def name_service=(service)
                Orocos::Async.name_service.name_services.each_with_index do |i,val|
                    if val == @delegator_obj
                        Orocos::Async.name_service.name_services[i] = service
                        break
                    end
                end
                reachable! service
            end
            def name_service
                @name_service ||= NameService.new(Orocos::CORBA.name_service.ip)
            end

            def get(name,options =Hash.new)
                name_service.get(name,options)
            end

            def proxy(name,options = Hash.new)
                name_service.proxy(name,options)
            end
        end

        class NameService < RemoteNameService
            extend Utilrb::EventLoop::Forwardable

            def initialize(host = "", reconnect: true)
                name_service = Orocos::CORBA::NameService.new(host)
                super(name_service, reconnect: reconnect)
            end
        end
    end
end

