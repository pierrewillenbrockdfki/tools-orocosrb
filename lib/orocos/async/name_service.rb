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

        def initialize(name_service, options = {})
            @options = Kernel.validate_options(
                options, { period: default_period, start: false, sync_key: nil,
                           known_errors: Orocos::Async::KNOWN_ERRORS,
                           event_loop: Orocos::Async.event_loop }
            )

            @stored_names = Set.new
            _, options_async = Kernel.filter_options @options, event_loop: nil
            super(name_service.name, @options[:event_loop])

            disable_emitting { reachable!(name_service) }
            @watchdog_timer =
                @event_loop.async_every(method(:names), options_async) do |names|
                    names.each do |name|
                        event(:task_added, name) if @stored_names.add?(name)
                    end

                    @stored_names.delete_if do |name|
                        next if names.include?(name)

                        event :task_removed, name
                        true
                    end
                end
            @watchdog_timer.doc = name
            @task_context_proxies = []
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
            options = if name_services.last.kind_of?(Hash)
                          name_services.pop
                      else
                          {}
                      end

            name_services = [Orocos::NameService.new(*name_services)]
            super(name_services.first, options)
        end

        def clear
            task_context_proxies.clear
            orig_clear
        end

        def proxy(name, options = {})
            if name_services.empty?
                Orocos.error "Orocos is not initialized!" unless Orocos.initialized?
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
            orig_add(name_service)
            event :name_service_added, name_service
        end

        # (see Orocos::NameServiceBase#add_front)
        #
        # Emits the name_service_added event
        def add_front(name_service)
            orig_add_front(name_service)
            event :name_service_added, name_service
        end

        # (see Orocos::NameServiceBase#remove)
        #
        # Emits the name_service_removed event
        def remove(name_service)
            removed = false
            name_services.delete_if do |ns|
                removed = true if name_service == ns
            end

            if removed
                event :name_service_removed, name_service
                true
            end
        end

        def get(name, options = {}, &block)
            async_options, other_options = Kernel.filter_options(
                options,
                {
                    sync_key: nil, raise: nil, event_loop: @event_loop,
                    period: nil, wait: nil
                }
            )

            if block
                p = proc do |task, error|
                    task = task.to_async(async_options) unless error
                    if block.arity == 2
                        block.call task, error
                    elsif !error
                        block.call task
                    end
                end
                orig_get name, other_options, &p
            else
                task = orig_get name, other_options
                task.to_async(async_options)
            end
        end

        # add methods which forward the call to the underlying name service
        forward_to :@delegator_obj,:@event_loop, :known_errors => Orocos::Async::KNOWN_ERRORS do
            methods = Orocos::NameService.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::NameService.instance_methods + [:method_missing]
            def_delegator :add, alias: :orig_add
            def_delegator :add_front, alias: :orig_add_front
            def_delegator :clear, alias: :orig_clear
            def_delegator :get, alias: :orig_get
            def_delegators methods
        end
    end

    module CORBA
        class NameService
            def self.new(*args)
                Orocos::CORBA::NameService.new(*args).to_async
            end
        end
    end
end
