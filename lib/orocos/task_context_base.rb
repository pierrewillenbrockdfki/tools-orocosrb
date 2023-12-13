require 'orocos/ports_searchable'

module Orocos
    # This class represents both RTT attributes and properties
    class AttributeBase
        # The underlying TaskContext instance
        attr_reader :task
        # The property/attribute name
        attr_reader :name
        # The attribute type, as a subclass of Typelib::Type
        attr_reader :type
        # If set, this is a Pocolog::DataStream object in which new values set
        # from within Ruby are set
        attr_accessor :log_stream
        # If set, this is an input port object in which new values set from
        # within Ruby are sent
        attr_accessor :log_port
        # The type name as registered in the orocos type system
        attr_reader :orocos_type_name

        def initialize(task, name, orocos_type_name)
            @task = task
            @name = name
            @orocos_type_name = orocos_type_name
            ensure_type_available(:fallback_to_null_type => true)
        end


        def full_name
            "#{task.name}.#{name}"
        end

        # @deprecated
        # Returns the name of the typelib type. Use #type.name instead.
        def type_name
            ensure_type_available
            type.name
        end

        def ==(other)
            name == other.name && task == other.task
        end

        def log_metadata
            Hash[
                "rock_task_model" => (task.model.name || ""),
                "rock_task_name" => task.name,
                "rock_task_object_name" => name,
                "rock_orocos_type_name" => orocos_type_name,
                "rock_cxx_type_name" => orocos_type_name
            ]
        end

        def ensure_type_available(options = Hash.new)
            if !type || type.null?
                @type = Orocos.find_type_by_orocos_type_name(@orocos_type_name, **options)
            end
        end

        def raw_read
            ensure_type_available
            value = type.new
            do_read(@orocos_type_name, value)
            value
        end

        # Read the current value of the property/attribute
        def read
            Typelib.to_ruby(raw_read)
        end

        # Sets a new value for the property/attribute
        def write(value, timestamp = Time.now, direct: false)
            ensure_type_available
            value = Typelib.from_ruby(value, type)
            do_write(@orocos_type_name, value, direct: direct)
            log_value(value, timestamp)
            value
        end

        # Write the current value of the property or attribute to #log_stream
        def log_current_value(timestamp = Time.now)
            log_value(read)
        end

        def log_value(value, timestamp = Time.now)
            if log_stream
                log_stream.write(timestamp, timestamp, value)
            end
            if log_port
                log_port.write(value)
            end
        end

        def new_sample
            ensure_type_available
            type.new
        end

        def pretty_print(pp) # :nodoc:
            pp.text "attribute #{name} (#{type.name})"
        end

        def doc?
            (doc && !doc.empty?)
        end

        def doc
            return unless task.model

            task.model.find_property(name)&.doc
        end
    end

    # Exception raised in TaskContext#initialize for tasks for which we can't determine the model
    #
    # This is a workaround: orocos.rb should work fine in these cases. However, it seems that it
    # currently does not, so block this case for now
    class NoModel < RuntimeError
    end

    # This methods must be implemented by
    # the child class of TaskContextBase
    module TaskContextBaseAbstract
        # Returns an object that represents the given port on the task
        # context. The returned object is either an InputPort or an OutputPort
        def port(_name)
            raise Orocos::NotFound, "#port is not implemented in #{self.class}"
        end

        # Returns an Attribute object representing the given attribute
        def attribute(_name)
            raise Orocos::NotFound, "#attribute is not implemented in #{self.class}"
        end

        # Returns a Property object representing the given property
        def property(_name)
            raise Orocos::NotFound, "#property is not implemented in #{self.class}"
        end

        # Returns an Operation object that represents the given method on the
        # remote component.
        def operation(_name)
            raise Orocos::NotFound, "#operation is not implemented in #{self.class}"
        end

        # Returns the array of the names of available properties on this task
        # context
        def property_names
            raise NotImplementedError
        end

        # Returns the array of the names of available attributes on this task
        # context
        def attribute_names
            raise NotImplementedError
        end

        # Returns the array of the names of available operations on this task
        # context
        def operation_names
            raise NotImplementedError
        end

        # Returns the names of all the ports defined on this task context
        def port_names
            raise NotImplementedError
        end

        # Reads the state
        def rtt_state
            raise NotImplementedError
        end

        # raises an runtime error if the task is not
        # reachable
        def ping
            raise NotImplementedError
        end

    end

    # Base implementation for Orocos::TaskContext
    class TaskContextBase
        include TaskContextBaseAbstract
        include PortsSearchable
        include Namespace

        RUNNING_STATES = []
        RUNNING_STATES[STATE_PRE_OPERATIONAL] = false
        RUNNING_STATES[STATE_STOPPED]         = false
        RUNNING_STATES[STATE_RUNNING]         = true
        RUNNING_STATES[STATE_RUNTIME_ERROR]   = true
        RUNNING_STATES[STATE_FATAL_ERROR]     = false
        RUNNING_STATES[STATE_EXCEPTION]     = false

        # Returns a task which provides the +type+ interface.
        #
        # Use Orocso.name_service.get(:provides => name) instead.
        def self.get_provides(type) # :nodoc:
            Orocos.name_service.get_provides(type)
        end

        # :call-seq:
        #   TaskContext.get(name) => task
        #   TaskContext.get(:provides => interface_name) => task
        #
        # In the first form, returns the TaskContext instance representing the
        # remote task context with the given name.
        #
        # In the second form, searches for a task context that implements the given
        # interface. This is doable only if orogen has been used to generate the
        # components.
        #
        # Raises Orocos::NotFound if the task name does not exist, if no task
        # implements the given interface, or if more than one task does
        # implement the required interface
        def self.get(options, process = nil)
            if options.kind_of?(Hash)
                # Right now, the only allowed option is :provides
                options = Kernel.validate_options options, :provides => nil
                return Orocos.name_service.get_provides(options[:provides].to_str)
            else
                raise ArgumentError, 'no task name' if options.nil?
                name = options.to_str
            end
            result = Orocos.name_service.get(name,{:process => process})
        end

        # Find one running tasks from the provided names. Raises if there is not
        # exactly one
        def self.find_one_running(*names)
            Orocos.name_service.find_one_running(*names)
        end

        # TODO this is bad performance wise
        # it will load the model and all extensions
        # use the nameservice for the check
        #
        # Returns true if +task_name+ is a TaskContext object that can be
        # reached
        def self.reachable?(task_name)
            Orocos.name_service.task_reachable? task_name
        end

        # Connects all output ports with the input ports of given task.
        # If one connection is ambiguous or none of the port is connected
        # an exception is raised. All output ports which does not match
        # any input port are ignored
        #
        # Instead of a task the method can also be called with a port
        # as argument
        def self.connect_to(task,task2,policy = Hash.new, &block)
            if task2.respond_to? :each_port
                count = 0
                task.each_port do |port|
                    next if !port.respond_to? :reader
                    if other = task2.find_input_port(port.type,nil)
                        port.connect_to other, policy, &block
                        count += 1
                    end
                end
                if count == 0
                    raise NotFound, "#{task.name} has no port matching the ones of #{task2.name}."
                end
            else # assuming task2 is a port
                if port = task.find_output_port(task2.type,nil)
                    port.connect_to task2, policy, &block
                else
                    raise NotFound, "no port of #{task.name} matches the given port #{task2.name}"
                end
            end
            self
        end

        # The IOR of this task context
        attr_reader :ior

        # The underlying process object that represents this node
        # It is non-nil only if this node has been started by orocos.rb
        attr_accessor :process

        # If set, this is a Pocolog::Logfiles object in which the values of
        # properties and attributes should be logged.
        #
        # Orocos.rb only logs the values that are set from within Ruby. There
        # are no ways to log the values changed from within the task context.
        attr_reader :configuration_log

        # Returns the last-known state
        attr_reader :current_state

        # A name => Attribute instance mapping of cached attribute objects
        attr_reader :attributes

        # A name => Property instance mapping of cached properties
        attr_reader :properties

        # A mapping from static numeric value to state names
        attr_reader :state_symbols

        # @param [String] name The name of the task.
        # @param [Hash] options The options.
        # @option options [Orocos::Process] :process The process supporting the task
        # @option options [String] :namespace The namespace of the task
        def initialize(name, namespace: nil, process: nil, model: nil)
            @ports = Hash.new
            @properties = Hash.new
            @attributes = Hash.new
            @state_queue = Array.new

            if namespace
                self.namespace, @name = namespace, name
            else
                self.namespace, @name = split_name(name)
                name = @name
            end
            @process    = process

            @process ||= Orocos.enum_for(:each_process).
                find do |p|
                    p.task_names.any? { |n| n == name }
                end

            if process
                process.register_task(self)
            end

            if model
                self.model = model
            else
                # Load the model from remote if it is not set yet
                self.model
            end

            if !@state_symbols
                @state_symbols = []
                @state_symbols[STATE_PRE_OPERATIONAL] = :PRE_OPERATIONAL
                @state_symbols[STATE_STOPPED]         = :STOPPED
                @state_symbols[STATE_RUNNING]         = :RUNNING
                @state_symbols[STATE_RUNTIME_ERROR]   = :RUNTIME_ERROR
                @state_symbols[STATE_EXCEPTION]       = :EXCEPTION
                @state_symbols[STATE_FATAL_ERROR]     = :FATAL_ERROR
                @error_states     = Set.new
                @runtime_states   = Set.new
                @exception_states = Set.new
                @fatal_states     = Set.new
                add_default_states
            end
        end

        # The full name of the task context
        def name
            map_to_namespace(@name)
        end

        def basename
            @name
        end

        # call-seq:
        #  task.each_operation { |a| ... } => task
        #
        # Enumerates the operation that are available on
        # this task, as instances of Orocos::Operation
        def each_operation(&block)
            if !block_given?
                return enum_for(:each_operation)
            end
            names = operation_names
            names.each do |name|
                yield(operation(name))
            end
        end

        # call-seq:
        #  task.each_property { |a| ... } => task
        #
        # Enumerates the properties that are available on
        # this task, as instances of Orocos::Attribute
        def each_property(&block)
            if !block_given?
                return enum_for(:each_property)
            end
            names = property_names
            names.each do |name|
                yield(property(name))
            end
        end

        # call-seq:
        #  task.each_attribute { |a| ... } => task
        #
        # Enumerates the attributes that are available on
        # this task, as instances of Orocos::Attribute
        def each_attribute(&block)
            if !block_given?
                return enum_for(:each_attribute)
            end

            names = attribute_names
            names.each do |name|
                yield(attribute(name))
            end
        end

        # call-seq:
        #  task.each_port { |p| ... } => task
        #
        # Enumerates the ports that are available on this task, as instances of
        # either Orocos::InputPort or Orocos::OutputPort
        def each_port(&block)
            if !block_given?
                return enum_for(:each_port)
            end

            port_names.each do |name|
                yield(port(name))
            end
            self
        end

        # Returns true if +name+ is the name of a attribute on this task context
        def has_attribute?(name)
            attribute_names.include?(name.to_str)
        end

        # Returns true if this task context has either a property or an attribute with the given name
        def has_property?(name)
            property_names.include?(name.to_str)
        end

        # Returns true if this task context has a command with the given name
        def has_operation?(name)
            operation_names.include?(name.to_str)
        end

        # Returns true if this task context has a port with the given name
        def has_port?(name)
            port_names.include?(name.to_str)
        end

        # Returns true if a documentation about the task is available
        # otherwise it returns false
        def doc?
            (doc && !doc.empty?)
        end

        # True if it is known that this task runs on the local machine
        #
        # This requires the process handling to be done by orocos.rb (the method
        # checks if the process runs on the local machine)
        def on_localhost?
            process && process.on_localhost?
        end

        # True if the given symbol is the name of a runtime state
        def runtime_state?(sym); @runtime_states.include?(sym) end
        # True if the given symbol is the name of an error state
        def error_state?(sym); @error_states.include?(sym) end
        # True if the given symbol is the name of an exception state
        def exception_state?(sym); @exception_states.include?(sym) end
        # True if the given symbol is the name of a fatal error state
        def fatal_error_state?(sym); @fatal_states.include?(sym) end

        # Returns true if the task is pre-operational
        def pre_operational?
            peek_current_state && peek_current_state == :PRE_OPERATIONAL
        end

        # Returns true if the task is in a state where code is executed. This
        # includes of course the running state, but also runtime error states.
        def running?
            runtime_state?(peek_current_state)
        end
        # Returns true if the task has been configured.
        def ready?; peek_current_state && (peek_current_state != :PRE_OPERATIONAL) end
        # Returns true if the task is in an error state (runtime or fatal)
        def error?
            error_state?(peek_current_state)
        end
        # Returns true if the task is in a runtime error state
        def runtime_error?
            state = self.peek_current_state
            error_state?(state) &&
                !exception_state?(state) &&
                !fatal_error_state?(state)
        end
        # Returns true if the task is in an exceptional state
        def exception?
            exception_state?(peek_current_state)
        end
        # Returns true if the task is in a fatal error state
        def fatal_error?
            fatal_error_state?(peek_current_state)
        end

        # Returns an array of symbols that give the tasks' state names from
        # their integer value. This is mostly for internal use.
        def available_states # :nodoc:
            if @states
                return @states
            end
        end

        # This is meant to be used internally
        # Returns the current task's state without "hiding" any state change to
        # the task's user.
        #
        # This is meant to be used internally

        def peek_current_state
            peek_state.last || @current_state
        end

        def peek_state
            current_state = rtt_state
            if (@state_queue.empty? && current_state != @current_state) || (@state_queue.last != current_state)
                @state_queue << current_state
            end
            @state_queue
        end

        def input_port(name)
            p = port(name)
            if p.respond_to?(:writer)
                return p
            else
                raise InterfaceObjectNotFound.new(self, name), "#{name} is an output port of #{self.name}, was expecting an input port"
            end
        end

        def output_port(name)
            p = port(name)
            if p.respond_to?(:reader)
                return p
            else
                raise InterfaceObjectNotFound.new(self, name), "#{name} is an input port of #{self.name}, was expecting an output port"
            end
        end

        # Returns an array of all the ports defined on this task context
        def ports
            enum_for(:each_port).to_a
        end

        # call-seq:
        #  task.each_input_port { |p| ... } => task
        #
        # Enumerates the input ports that are available on this task, as
        # instances of Orocos::InputPort
        def each_input_port
            each_port do |p|
                yield(p) if p.respond_to?(:writer)
            end
        end

        # call-seq:
        #  task.each_output_port { |p| ... } => task
        #
        # Enumerates the input ports that are available on this task, as
        # instances of Orocos::OutputPort
        def each_output_port
            each_port do |p|
                yield(p) if p.respond_to?(:reader)
            end
        end

        # Returns the Orogen specification object for this task instance.
        # This is available only if the deployment in which this task context
        # runs has been generated by orogen *and* this deployment has been
        # started by this Ruby instance
        #
        # To get the Orogen specification for the task context itself (an
        # OroGen::Spec::TaskContext instance), use {#model}.
        #
        # @return [OroGen::Spec::TaskDeployment]
        # @see model
        def info
            if process
                @info ||= process.orogen.task_activities.find { |act| act.name == name }
            end
        end

        # Returns a documentation string describing the task
        # If no documentation is available it returns nil
        def doc
            model.doc if model
        end


        # True if we got a state change announcement
        def state_changed?
            peek_state
            !@state_queue.empty?
        end

        # Returns true if the remote task context can still be reached through
        # and false otherwise.
        def reachable?
            ping
            true
        rescue Orocos::ComError
            false
        end

        # Connects all output ports with the input ports of given task.
        # If one connection is ambiguous or none of the port is connected
        # an exception is raised. All output ports which does not match
        # any input port are ignored
        #
        # Instead of a task the method can also be called with a port
        # as argument
        def connect_to(task,policy = Hash.new)
            TaskContextBase.connect_to(self,task,policy)
        end

        def to_s
            "#<TaskContextBase: #{self.class.name}/#{name}>"
        end

        def inspect
            "#<#{self.class}: #{self.class.name}/#{name}>"
        end

        # @return [Symbol] the toplevel state that corresponds to +state+, i.e.
        #   the value returned by #rtt_state when #state returns 'state'
        def toplevel_state(state)
            if exception_state?(state) then :EXCEPTION
            elsif fatal_state?(state) then :FATAL_ERROR
            elsif error_state?(state) then :RUNTIME_ERROR
            elsif runtime_state?(state) then :RUNNING
            else state
            end
        end

        def add_default_states
            @error_states   << :RUNTIME_ERROR << :FATAL_ERROR << :EXCEPTION
            @runtime_states << :RUNNING << :RUNTIME_ERROR
            @exception_states << :EXCEPTION
            @fatal_states     << :FATAL_ERROR
        end

        #load all informations from the model
        def model=(model)
            if model
                @model = model

                @state_symbols = model.each_state.map { |name, type| name.to_sym }
                @error_states  = model.each_state.
                    map { |name, type| name.to_sym if (type == :error || type == :exception || type == :fatal) }.
                    compact.to_set
                @exception_states  = model.each_state.
                    map { |name, type| name.to_sym if type == :exception }.
                    compact.to_set
                @runtime_states = model.each_state.
                    map { |name, type| name.to_sym if (type == :error || type == :runtime) }.
                    compact.to_set
                @fatal_states = model.each_state.
                    map { |name, type| name.to_sym if type == :fatal }.
                    compact.to_set

                if ext = Orocos.extension_modules[model.name]
                    ext.each { |m_ext| extend(m_ext) }
                end
                add_default_states
            else @model = nil
            end
        end

        # @return [OroGen::Spec::TaskContext,nil] the oroGen model that describes this node
        def model
            if @model
                @model
            elsif info && info.context
                self.model = info.context
            else
                nil
            end
        end

        # True if this task's model is a subclass of the provided class name
        #
        # This is available only if the deployment in which this task context
        # runs has been generated by orogen.
        def implements?(class_name)
            model && model.implements?(class_name)
        end

        # Resolves the model of a port
        #
        # @return [OroGen::Spec::OutputPort,nil]
        def output_port_model(name)
            if port_model = model.each_output_port.find { |p| p.name == name }
                port_model
            else model.find_dynamic_output_ports(name, nil).first
            end
        end

        # Resolves the model of a port
        #
        # @return [OroGen::Spec::InputPort,nil]
        def input_port_model(name)
            if port_model = model.each_input_port.find { |p| p.name == name }
                port_model
            else model.find_dynamic_input_ports(name, nil).first
            end
        end

        # Returns the state of the task, as a symbol. The possible values for
        # all task contexts are:
        #
        #   :PRE_OPERATIONAL
        #   :STOPPED
        #   :ACTIVE
        #   :RUNNING
        #   :RUNTIME_WARNING
        #   :RUNTIME_ERROR
        #   :FATAL_ERROR
        #
        # If the component is an oroGen component on which custom states have
        # been defined, these custom states are also reported with their name.
        # For instance, after the orogen definition
        #
        #   runtime_states "CUSTOM_RUNTIME"
        #
        # #state will return :CUSTOM_RUNTIME if the component goes into that
        # state.
        #
        # If +return_current+ is true, the current component state is returned.
        # Otherwise, only the next state in the state queue is returned. This is
        # only valid for oroGen components with extended state support (for
        # which all state changes are saved instead of only the last one)
        def state(return_current = true)
            peek_state
            if @state_queue.empty?
                @current_state
            elsif return_current
                @current_state = @state_queue.last
                @state_queue.clear
            else
                @current_state = @state_queue.shift
            end
            @current_state
        end

        # Returns all states which were received since the last call
        # and sets the current state to the last one.
        def states
            peek_state
            if !@state_queue.empty?
                @current_state = @state_queue.last
                @state_queue,old = [],@state_queue
                old
            else
                []
            end
        end

        def pretty_print(pp) # :nodoc:
            pp.text "Component #{name}"
            pp.breakable
            pp.text "  state: #{peek_current_state}"
            pp.breakable

            [['attributes', each_attribute], ['properties', each_property]].each do |kind, enum|
                objects = enum.to_a
                if objects.empty?
                    pp.text "No #{kind}"
                    pp.breakable
                else
                    pp.text "#{kind.capitalize}:"
                    pp.breakable
                    pp.nest(2) do
                        pp.text "  "
                        objects.each do |o|
                            o.pretty_print(pp)
                            pp.breakable
                        end
                    end
                    pp.breakable
                end
            end

            ports = enum_for(:each_port).to_a
            if ports.empty?
                pp.text "No ports"
                pp.breakable
            else
                pp.text "Ports:"
                pp.breakable
                pp.nest(2) do
                    pp.text "  "
                    each_port do |port|
                        port.pretty_print(pp)
                        pp.breakable
                    end
                end
                pp.breakable
            end
        end

        def method_missing(m, *args) # :nodoc:
            m = m.to_s
            if m =~ /^(\w+)=/
                name = $1
                begin
                    return property(name).write(*args)
                rescue Orocos::NotFound
                end

            else
                if has_port?(m)
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments for #{m}, got #{args.size}"
                    end
                    return port(m)
                elsif has_operation?(m)
                    return operation(m).callop(*args)
                elsif has_property?(m) || has_attribute?(m)
                    if !args.empty?
                        raise ArgumentError, "expected zero arguments for #{m}, got #{args.size}"
                    end
                    prop = if has_property?(m) then property(m)
                           else attribute(m)
                           end
                    value = prop.read
                    if block_given?
                        yield(value)
                        prop.write(value)
                    end
                    return value
                end
            end
            super(m.to_sym, *args)
        end

        def to_h
            Hash[
                name: name,
                model: model.to_h,
                state: state
            ]
        end
    end

    class << self
        attr_reader :extension_modules
    end
    @extension_modules = Hash.new { |h, k| h[k] = Array.new }

    # Requires orocos.rb to extend tasks of the given model with the given
    # block.
    #
    # For instance, the #log method that is defined on every logger task is
    # implemented with
    #
    #  Orocos.extend_task 'logger::Logger' do
    #    def log(port, buffer_size = 25)
    #      # setup the logging component to log the given port
    #    end
    #  end
    #
    def self.extend_task(model_name, &block)
        extension_modules[model_name] << Module.new(&block)
    end
end
