module Orocos
    # Returns the global name service abstracting all underlying name services.
    # This should be the default way to acquire an handle to an Orocos Task by
    # its name. If the IOR of the task is already known {TaskContext} should
    # directly be used.
    #
    # @example getting a remote/local task context.
    #   require 'orocos'
    #   Orocos.initialize
    #   task = Orocos.name_service.get "task_name"
    #
    # @example changing the default underlying CORBA name service
    #   Orocos::CORBA.name_service.ip = "host_name"
    #   Orocos.initialize
    #   task = Orocos.name_service.get 'task_name'
    #
    # @example adding a second CORBA name service
    #   Orocos.name_service << Orocos::CORBA::NameService.new("192.168.101.12")
    #   Orocos.initialize
    #   task = Orocos.name_service.get 'task_name'
    #
    # @example adding a second CORBA name service having a namespace
    #   Orocos.name_service << Orocos::CORBA::NameService.new("192.168.101.12",:namespace => "robot")
    #   Orocos.initialize
    #   task = Orocos.name_service.get 'robot/task_name'
    #
    # @example adding an Avahi name service
    #   Orocos.name_service << Orocos::Avahi::NameService.new("_robot._tcp")
    #   Orocos.initialize
    #   task = Orocos.name_service.get 'task_name'
    #
    # @return [Orocos::NameService] The name service
    def self.name_service
        @name_service ||= NameService.new()
    end

    def self.name_service=(name_service)
        @name_service = name_service
    end

    # @deprecated
    #
    # Returns the task names that are registered on CORBA
    #
    # You should use Orocos.name_service.names
    def self.task_names
        name_service.names
    end

    # Enumerates the tasks that are currently available on this sytem (i.e.
    # registered on the global name service {Orocos.name_service}).
    #
    # @yield [TaskContext] code block which is called for each TaskContext
    def self.each_task(&block)
        Orocos.name_service.each_task(&block)
    end

    # Removes dangling references from all name services added to the global
    # name service {Orocos.name_service}
    def self.cleanup
        name_service.cleanup
    end

    # (see NameService#get)
    def self.get(name, options = Hash.new)
        Orocos.name_service.get(name, options)
    end

    # Base class for all Orocos name services. An orocos name service is used
    # to find local and remote Orocos Tasks based on their name and namespace.
    #
    # @author Alexander Duda
    class NameServiceBase
        attr_accessor :name

        # Checks if a {TaskContext} with the given name is reachable.
        #
        # @param [String] name the name if the TaskContext
        # @return [Boolean]
        def task_reachable?(name)
            get(name)
            true
        rescue Orocos::NotFound
            false
        end

        # Gets an handle to a local/remote Orocos Task having the given name.
        #
        # @param [String] name the name of the {TaskContext}
        # @param [Hash] options the options used by the name service to find the {TaskContext}
        # @option options [String] :name Overwrites The real name of the task
        # @option options [Orocos::Process] :process The process supporting the task
        #
        # @return [Orocos::TaskContext,Orocos::Log::TaskContext]
        # @raise [Orocos::NotFound] if no {TaskContext} can be found
        #
        # @see Orocos::NameService
        def get(name,options=Hash.new)
            raise NotImplementedError
        end

        # return [String] the name of the name service
        def name
            @name || self.class.name
        end

        # Gets the IOR for the given Orocos Task having the given name.
        #
        # @param [String] name the name of the TaskContext
        # @return [String]
        # @raise [Orocos::NotFound] if the TaskContext cannot be found
        def ior(name)
            raise NotImplementedError
        end

        # Returns all Orocos Task names known by the name service
        # inclusive the namespace of the NameService instance.
        #
        # @return [Array<String>]
        def names
            raise NotImplementedError
        end

        # True if +name+ is a valid name inside this service's namespace
        def same_namespace?(name)
            true
        end

        # Checks if the name service is reachable if not it
        # raises a ComError.
        #
        # @return [nil]
        # @raise [Orocos::ComError]
        def validate
        end

        # Checks if the name service is reachable.
        #
        # @return [Boolean]
        def reachable?
            validate
            true
        rescue
            false
        end

        # Returns an handle to the {TaskContext} which provides
        # the +type+ interface.
        #
        # @param [String] type the type
        # @return [Orocos::TaskContext]
        # @raise [Orocos::NotFound]
        def get_provides(type) # :nodoc:
            results = enum_for(:each_task).find_all do |task|
                task.implements?(type)
            end
            if results.empty?
                raise Orocos::NotFound, "no task implements #{type}"
            elsif results.size > 1
                candidates = results.map { |t| t.name }.join(", ")
                raise Orocos::NotFound, "more than one task implements #{type}: #{candidates}"
            end
            get(results.first.name)
        end

        # Calls the given code block for all reachable {TaskContext} known by
        # the name service.
        #
        # @yield [TaskContext] code block which is called for each TaskContext
        def each_task
            return enum_for(__method__) if !block_given?
            names.each do |name|
                task = begin
                           get(name)
                       rescue Orocos::NotFound
                       end
                yield(task) if task
            end
        end

        # Find exactly one running tasks from the provided names.
        #
        # @param [String,Array<String>] names the names
        # @return [Orocos::TaskContext]
        # @raise [RuntimeError] if none of the tasks are running, reachable or more than one of them is running.
        def find_one_running(*names)
            candidates = names.map do |name|
                begin get name
                rescue Orocos::NotFound
                end
            end.compact

            if candidates.empty?
                raise Orocos::NotFound, "cannot find any tasks matching #{names.join(", ")}"
            end

            running_candidates = candidates.find_all(&:running?)
            if running_candidates.empty?
                raise Orocos::NotFound, "none of #{names.join(", ")} are running"
            elsif running_candidates.size > 1
                raise Orocos::NotFound, "multiple candidates are running: #{running_candidates.map(&:name)}"
            else
                running_candidates.first
            end
        end
    end

    # This name service abstracts all underlying name services. By default
    # there is one global instance accessible via {Orocos.name_service} which
    # has by default one {Orocos::CORBA::NameService} instance as underlying
    # name service.
    #
    # @author Alexander Duda
    #
    # @see Orocos::CORBA.name_service
    # @see Orocos::CORBA::NameService
    # @see Orocos::Avahi::NameService
    #
    class NameService < NameServiceBase
        include Namespace

        # @return [Array] The array with all underlying name services. The order implies the search order.
        attr_accessor :name_services

        # Returns a new instance of NameService
        #
        # @param [NameServiceBase,Array<NameServiceBase>] name_services The initial underlying name services
        # @return [NameService]
        def initialize(*name_services)
            @name_services = name_services
        end

        #(see Namespace#same_namespace?)
        def same_namespace?(name)
            name_services.any? do |service|
                service.same_namespace?(name)
            end
        end

        # Enumerates the name services registered on this global name service
        #
        # @yield [TaskContext]
        def each(&block)
            @name_services.each(&block)
        end

        # @return [Array] The array with all underlying name services
        # @raise Orocos::NotFound if no name service was added
        def name_services
            @name_services
        end

        # Adds a name service.
        #
        # @param [NameServiceBase] name_service The name service.
        def <<(name_service)
            add(name_service)
        end

        # Adds a name service to the top of {#name_services}
        #
        # @param [NameServiceBase] name_service The name service.
        def add_front(name_service)
            return if @name_services.include? name_service

            @name_services.insert(0,name_service)
        end

        # (see #<<)
        def add(name_service)
            return if @name_services.include? name_service

            @name_services << name_service
        end

        # Remove a name service from the set of resolvants
        #
        # @param [NameServiceBase] name_service the name service object
        # @return [true,false] true if the name service was registered, false
        #   otherwise
        def remove(name_service)
            if @name_services.include? name_service
                @name_services.delete name_service
                true
            end
        end

        # Finds an underlying name service of the given class
        #
        # @param [class] klass the class
        def find(klass)
            @name_services.find do |service|
                true if service.is_a? klass
            end
        end

        # Checks if an underlying name service is of the given class
        #
        # @param [class] klass the class
        # @return [Boolean]
        def include?(klass)
            !!find(klass)
        end

        # Checks if there is at least one underlying name service
        #
        # @return [Boolean]
        def initialized?
            !@name_services.empty?
        end

        #(see NameServiceBase#get)
        def get(name,options = Hash.new)
            name_services.each do |service|
                begin
                    if service.same_namespace?(name)
                        task_context = service.get(name,options)
			return task_context if task_context
                    end
                rescue Orocos::NotFound
                end
            end
            raise Orocos::NotFound, error_message(name)
        end

        #(see NameServiceBase#ior)
        def ior(name)
            verify_same_namespace(name)
            name_services.each do |service|
                next if !service.respond_to?(:ior)
                begin
                    if service.same_namespace?(name)
                        return service.ior(name)
                    end
                rescue Orocos::NotFound
                end
            end
            raise Orocos::NotFound, error_message(name)
        end

        #(see NameServiceBase#names)
        def names
            names = name_services.collect do |service|
                begin
                    service.names
                rescue Orocos::CORBAError,Orocos::CORBA::ComError
                    []
                end
            end
            names.flatten.uniq
        end

        # Calls cleanup on all underlying name services which support cleanup
        def cleanup
            name_services.each do |service|
                service.cleanup
            end
        end

	# remove the service from the list of services
	def delete service
	    @name_services.delete service
	end

        # Removes all underlying name services
        def clear
            @name_services.clear
        end

        private
        # NameService does not support its own namespace as it abstracts all underlying name services.
        # Therefore, overwrite the one from the included module.
        def namespace=(name)
        end

        # Generates an error message if a {TaskContext} of the given name cannot be found
        #
        # @param [String] name The name of the task
        def error_message(name)
            if name_services.empty?
                "the remote task context #{name} could not be resolved, because no name services are registered"
            else
                "the remote task context #{name} could not be resolved using following name services (in priority order): #{name_services.join(', ')}"
            end
        end

    end

    module Local

        # Name service which is used by {Orocos::Log::Replay} to register {Orocos::Log::TaskContext} on the
        # global name service {Orocos.name_service}
        # @author Alexander Duda
        class NameService < NameServiceBase
            include Namespace

            attr_reader :registered_tasks

            # A new NameService instance
            #
            # @param [Hash<String,Orocos::TaskContext>] tasks The tasks which are known by the name service.
            # @note The namespace is always "Local"
            def initialize(tasks =[])
                raise ArgumentError, "wrong argument - Array was expected" unless tasks.is_a? Array
                @registered_tasks = Array.new
		@alias = {}
                tasks.each do |task|
                    register(task)
                end
            end

            #(see NameServiceBase#name)
            def name
                super + ":Local"
            end

            # Returns an Async object that maps to this name service
            def to_async(options = Hash.new)
                Orocos::Async::NameService.new(self.class.new(registered_tasks))
            end

            #(see NameServiceBase#get)
            def get(name,options=Hash.new)
                options = Kernel.validate_options options,:name,:namespace,:process
		# search alias hash first
		task = @alias[name]
		return task if task
		# otherwise look in the registered tasks
                task = @registered_tasks.find do |task|
                    if task.name == name || task.basename == name
                        true
                    end
                end
                raise Orocos::NotFound, "task context #{name} cannot be found." unless task
                task
            end

            # Registers the given {Orocos::TaskContext} on the name service.
	    # If a name is provided, it will be used as an alias. If no name is
	    # provided, the name of the task is used. This is true even if the
	    # task name is renamed later.
            #
            # @param [Orocos::TaskContext] task The task.
            # @param [String] name Optional name which is used to register the task.
            def register(task, name = nil)
		if name.nil?
		    @registered_tasks << task unless @registered_tasks.include? task
		else
		    @alias[name] = task
		end
            end

            # Local is a collection of name spaces
            def same_namespace?(name_space)
                true
            end

            # Deregisters the given name or task from the name service.
            #
            # @param [String,TaskContext] name The name or task
            def deregister(name)
		# deregister from alias
		task = @alias[name]
		@alias.delete name if task

		# and also the task list
                task = get(name)
                @registered_tasks.delete task
            rescue Orocos::NotFound
            end

            # (see NameServiceBase#names)
            def names
                ns = registered_tasks.map &:name
		ns + @alias.keys
            end
        end
    end

    module CORBA
        class << self
            # Returns the global CORBA name service which is used to register
            # all Orocos Tasks started by the ruby instance and is by default
            # added to the global Orocos::NameService instance
            # {Orocos.name_service}
            #
            # @return [Orocos::CORBA::NameService] The global CORBA name service
            def name_service
                @name_service ||= NameService.new
            end

            # Sets the default CORBA name service and replaces the old instance stored
            # in {Orocos#name_service} if there is one.
            #
            # @param [Orocos::CORBA::NameService] service the name service
            def name_service=(service)
                if service.respond_to? :to_str
                    # To support deprecated way of setting the host name
                    CORBA.warn "Orocos::CORBA.name_service = 'host_name' is deprecated."
                    CORBA.warn "Use Orocos::CORBA.name_service.ip = 'host_name' instead."
                    name_service.ip = service
                else
                    #check if the old name service is added to the global Orocos.name_service
                    #and replace it with the new one
                    Orocos.name_service.name_services.each_with_index do |i,val|
                        if val == @name_service
                            Orocos.name_service.name_services[i] = service
                            break
                        end
                    end
                    @name_service = service
                end
            end

            # Calls cleanup on the global Orocos::CORBA::NameService instance {Orocos::CORBA.name_service}
            #
            # @see Orocos::CORBA::NameService.cleanup
            def cleanup
                name_service.cleanup
            end
        end

        # Name service client to access the CORBA name service and retrieve an
        # handle to registered Orocos Tasks.
        # By default there is one global instance accessible via {Orocos::CORBA.name_service}
        # which is also by default added to {Orocos.name_service}
        #
        # The default {Orocos::CORBA.name_service} is used to register all Orocos Tasks started
        # by the ruby instance no matter if it was removed from {Orocos.name_service} or not.
        #
        # @see Orocos.name_service
        # @author Alexander Duda
        class NameService < NameServiceBase
            include Namespace

            def initialize(host = "")
                self.ip = host
            end

            #(see NameServiceBase#name)
            def name
                "CORBA:#{namespace}"
            end

            def namespace
                ip
            end

            # Sets the ip address or host name where the CORBA name service is running
            #
            # @param [String] host The ip address or host name
            def ip=(host)
                reset(host)
            end

            # @return [String] The ip where the client tries to reach the CORBA name service
            def ip
                do_ip
            end

            # @return [String] The port where the client tries to reach the CORBA name service
            def port
                do_port
            end

            # Bind an existing task under an alternative name
            #
            # @param [TaskContext] task the task context
            # @param [String] name the name
            def bind(task, name)
                do_bind(task, name)
            end

            # The async-access object for this name service
            # @param (see Orocos::Async::CORBA::NameService#initialize)
            # @return [Orocos::Async::CORBA::NameService]
            def to_async(reconnect: true)
                Orocos::Async::NameService.new(self.class.new(ip))
            end

            # Resets the CORBA name service client.
            #
            # @param [String] ip The ip address or host name where the CORBA name service is running
            # @param [String] port The port of the CORBA name service
            def reset(ip=ip(),port=port())
                do_reset(ip,port)
            end

            #(see NameServiceBase#ior)
            def ior(name)
                verify_same_namespace(name)
                CORBA.refine_exceptions("corba naming service(#{ip})") do
                    do_ior(basename(name))
                end
            end

            # (see NameServiceBase#names)
            def names
                result = CORBA.refine_exceptions("corba naming service(#{ip})") do
                    do_task_context_names.find_all { |n| n !~ /^orocosrb_(\d+)$/ }
                end
                map_to_namespace(result)
            end

            # (see NameServiceBase#get)
            def get(name = nil, namespace: nil, process: nil, ior: nil)
                if ior
                    Orocos::TaskContext.new(ior, namespace: namespace, process: process)
                else
                    ns,_ = split_name(name)
                    ns = if !ns || ns.empty?
                             self.namespace
                         else
                             ns
                         end
                    namespace ||= (ns || "")
                    Orocos::TaskContext.new(ior(name), namespace: namespace, process: process)
                end
            rescue ComError => e
                raise Orocos::NotFound, "task context #{name} is registered but cannot be reached."
            end

            # Registers the IOR of the given {Orocos::TaskContext} on the CORBA name service.
            #
            # @param [Orocos::TaskContext] task The task.
            # @param [String] name The name which is used to register the task.
            def register(task,name=task.name)
                verify_same_namespace(name)
                do_bind(task,basename(name))
            end

            # Deregisters the given name or task from the name service.
            #
            # @param [String,TaskContext] name The name or task
            def deregister(name)
                name = if name.respond_to? :name
                           name.name
                       else
                           name
                       end
                verify_same_namespace(name)
                CORBA.refine_exceptions("corba naming service #{ip}") do
                    do_unbind(basename(name))
                end
            end

            #(see NameServiceBase#validate)
            def validate
                CORBA.refine_exceptions("corba naming service #{ip}") do
                    begin
                        do_validate
                    rescue Orocos::ComError => e
                        CORBA.warn "Name service is unreachable: #{e.message}\n"
                        CORBA.warn "You can try to fix this manually by restarting the nameserver:\n"
                        CORBA.warn "    sudo /etc/init.d/omniorb4-nameserver stop\n"
                        CORBA.warn "    sudo rm -f /var/lib/omniorb/*\n"
                        CORBA.warn "    sudo /etc/init.d/omniorb4-nameserver start\n"
                        raise
                    end
                end
            end

            # Removes dangling references from the name service
            #
            # This method removes objects that are not accessible anymore from the
            # name service
            def cleanup
                names = names().dup
                names.each do |n|
                    begin
                        CORBA.info "trying task context #{n}"
                        get(n)
                    rescue Orocos::NotFound => e
                        deregister(n)
                        CORBA.warn "deregistered dangling CORBA name #{n}: #{e.message}"
                    end
                end
            end

        end
    end

    class CORBANameService < NameServiceBase
    end

    module Avahi

        # Name service to access Orocos Tasks which are publishing their IOR via Avahi
        class NameService < NameServiceBase

            # A new instance of NameService which is listening on the given search domain.
            # The serach domain must have a ._tcp or ._udp at the end for a protocol type.
            #
            # @param [String] searchdomain The search domain the name service is listening to (_myrobot._tcp / _myrobot._udp)
            def initialize(searchdomain)

                raise ArgumentError,"no serachdomain is given" unless searchdomain

                @registered_tasks = Hash.new
                @searchdomain = searchdomain

                begin
                    require 'servicediscovery'
                    @avahi_nameserver = ::Avahi::ServiceDiscovery.new
                rescue LoadError
                    raise LoadError, "NameService: 'distributed_nameserver' needs to be installed for Avahi nameservice support"
                end
                # Start listening on the given domains (this does refer to the _myservice._tcp service domain and not(!) the .local domain)
                begin
                    @avahi_nameserver.listen_on(Array(@searchdomain))
                rescue RuntimeError
                    raise ArgumentError, "given search domain #{searchdomain} is invalid. Use '_myservice._tcp'."
                end
            end

            #(see NameServiceBase#names)
            def names
                @avahi_nameserver.get_all_services.uniq
            end

            def same_namespace?(name)
                true
            end

            # Registers the IOR of the given {Orocos::TaskContext} on the Avahi name service
            #
            # @param [Orocos::TaskContext] task The task.
            # @param [String] name The name which is used to register the task.
            def register(task,name=task.name)
                existing_service = @registered_tasks[name]
                service = existing_service || ::Avahi::ServiceDiscovery.new
                service.set_description("IOR",task.ior)
                if existing_service
                    service.update
                else
                    @registered_tasks[name] = service
                    service.publish(name, @searchdomain)
                end
                service
            end

            # Deregisters the given name or task from the name service.
            #
            # @param [String,TaskContext] task The name or task
            # @note This only works for tasks which were registered by the same ruby instance.
            def deregister(task)
                name = if task.respond_to? :name
                           task.name
                       else
                           task
                       end
                @registered_tasks.delete name
            end

            #(see NameServiceBase#ior)
            def ior(name)
                services = @avahi_nameserver.find_services(name)
                if services.empty?
                    raise Orocos::NotFound, "Avahi nameservice could not find a task named '#{name}'"
                elsif services.size > 1
                    warn "Avahi: '#{name}' found multiple times. Possibly due to publishing on IPv4 and IPv6, or on multiple interfaces -- picking first one in list"
                end
                ior = services.first.get_description("IOR")
                if !ior || ior.empty?
                    raise Orocos::NotFound, "Avahi nameservice could not retrieve an ior for task #{name}"
                end
                ior
            end

            #(see NameServiceBase#get)
            def get(name,options = Hash.new)
                options = Kernel.validate_options options,:name,:namespace,:process
                ns,_ = Namespace.split_name(name)
                options[:namespace] ||= ns
                Orocos::TaskContext.new(ior(name),options)
            rescue Orocos::CORBA::ComError => e
                raise Orocos::NotFound, "task context #{name} is registered but cannot be reached."
            end
        end
    end
end

