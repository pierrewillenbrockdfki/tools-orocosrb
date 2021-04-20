require 'forwardable'
require 'delegate'

module Orocos::Async
    class AttributeBaseProxy < ObjectBase
        extend Forwardable
        define_events :change,:raw_change
        attr_reader :raw_last_sample

        methods = Orocos::AttributeBase.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods -= AttributeBaseProxy.instance_methods + [:method_missing,:name]
        methods << :type
        def_delegators :@delegator_obj,*methods

        def initialize(task_proxy,attribute_name,options=Hash.new)
            @type = options.delete(:type)
            @options = options
            super(attribute_name,task_proxy.event_loop)
            @task_proxy = task_proxy
            @raw_last_sample = nil
        end

        def to_s
            typename = @type&.name || "unknown_t"
            "#<#{self.class.name} #{task.name}.#{name}[#{typename}]>"
        end

        def invalidate_delegator!
            super
        end

        def task
            @task_proxy
        end

        def full_name
            "#{task.name}.#{name}"
        end

        def type_name
            type.name
        end

        def type
            raise Orocos::NotFound, "#{self} is not reachable" unless @type

            @type
        end

        # returns true if the proxy stored the type
        def type?
            !!@type
        end

        def new_sample
            type.new
        end

        def last_sample
            Typelib.to_ruby(@raw_last_sample) if @raw_last_sample
        end

        def reachable!(attribute,options = Hash.new)
            @options = attribute.options
            if @type && @type != attribute.type && @type.name != attribute.orocos_type_name
                raise RuntimeError, "the given type #{@type} for attribute #{attribute.name} differes from the real type name #{attribute.type}"
            end
            @type = attribute.type
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            @raw_last_sample = attribute.raw_last_sample
            super(attribute,options)
            proxy_event(@delegator_obj, @delegator_obj.event_names - [:reachable])
        end

        def unreachable!(options=Hash.new)
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?

            super(options)
        end

        def period
            @options[:period]
        end

        def period=(period)
            @options[:period] = period
            @delegator_obj.period = period if valid_delegator?
        end

        def really_add_listener(listener)
            return super unless listener.use_last_value?

            if listener.event == :change
                sample = last_sample
                if sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            elsif listener.event == :raw_change
                sample = raw_last_sample
                if sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            end
            super
        end

        def on_change(policy = Hash.new,&block)
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !valid_delegator?
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "ProxyProperty #{full_name} cannot emit :change with different policies."
                           Orocos.warn "The current policy is: #{@options}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @options
                       end
            on_event :change,&block
        end

        def on_raw_change(policy = Hash.new,&block)
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !valid_delegator?
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "ProxyProperty #{full_name} cannot emit :raw_change with different policies."
                           Orocos.warn "The current policy is: #{@options}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @options
                       end
            on_event :raw_change,&block
        end

        private
        def process_event(event_name,*args)
            @raw_last_sample = args.first if event_name == :raw_change
            super
        end

    end

    class PropertyProxy < AttributeBaseProxy
    end

    class AttributeProxy < AttributeBaseProxy
    end

    class PortProxy < ObjectBase
        extend Forwardable
        define_events :data,:raw_data

        methods = Orocos::Port.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods -= PortProxy.instance_methods + [:method_missing,:name]
        methods << :write
        methods << :type
        def_delegators :@delegator_obj,*methods

        def initialize(task_proxy,port_name,options=Hash.new)
            super(port_name,task_proxy.event_loop)
            @task_proxy = task_proxy
            @type = options.delete(:type)
            @options = options
            @raw_last_sample = nil
        end

        def to_s
            typename = @type&.name || "unknown_t"
            "#<#{self.class.name} #{@task_proxy.name}.#{name}[#{typename}]>"
        end

        def type_name
            type.name
        end

        def full_name
            "#{@task_proxy.name}.#{name}"
        end

        def type
            raise Orocos::NotFound, "#{self} is not reachable" unless @type

            @type
        end

        # returns true if the proxy stored the type
        def type?
            !!@type
        end

        def new_sample
            type.new
        end

        def to_async(options=Hash.new)
            task.to_async(options).port(self.name)
        end

        def to_proxy(options=Hash.new)
            self
        end

        def task
            @task_proxy
        end

        def input?
            if !valid_delegator?
                true
            elsif @delegator_obj.respond_to?(:writer)
                true
            else
                false
            end
        end

        def output?
            if !valid_delegator?
                true
            elsif @delegator_obj.respond_to?(:reader)
                true
            else
                false
            end
        end

        def reachable?
            super && @delegator_obj.reachable?
        end

        def reachable!(port,options = Hash.new)
            raise ArgumentError, "port must not be kind of PortProxy" if port.is_a? PortProxy
            if @type && @type != port.type && @type.name != port.orocos_type_name
                raise RuntimeError, "the given type #{@type} for port #{port.full_name} differes from the real type name #{port.type}"
            end

            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            super(port,options)
            proxy_event(@delegator_obj,@delegator_obj.event_names-[:reachable])
            @type = port.type

            #check which port we have
            if port.respond_to?(:reader)
                @raw_last_sample = port.raw_last_sample
            elsif number_of_listeners(:data) != 0
                raise RuntimeError, "Port #{name} is an input port but callbacks for on_data are registered"
            end
        end

        def unreachable!(options = Hash.new)
            remove_proxy_event(@delegator_obj,@delegator_obj.event_names) if valid_delegator?
            super(options)
        end

        # returns a sub port for the given subfield
        def sub_port(subfield)
            raise RuntimeError , "Port #{name} is not an output port" if !output?

            SubPortProxy.new(self,subfield)
        end

        def period
            if @options.has_key? :period
                @options[:period]
            else
                nil
            end
        end

        def period=(period)
            raise RuntimeError, "Port #{name} is not an output port" if !output?
            @options[:period] = period
            @delegator_obj.period = period if valid_delegator?
        end

        def last_sample
            if @raw_last_sample
                Typelib.to_ruby(@raw_last_sample)
            end
        end

        def raw_last_sample
            @raw_last_sample
        end

        def really_add_listener(listener)
            return super unless listener.use_last_value?

            if listener.event == :data
                if sample = last_sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            elsif listener.event == :raw_data
                if sample = raw_last_sample
                    event_loop.once do
                        listener.call sample
                    end
                end
            end
            super
        end

        def on_data(policy = Hash.new,&block)
            on_raw_data policy do |sample|
                yield Typelib::to_ruby(sample,type)
            end
        end

        def on_raw_data(policy = Hash.new,&block)
            raise RuntimeError , "Port #{name} is not an output port" if !output?
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !valid_delegator?
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "Changing global reader policy for #{full_name} from #{@options} to #{policy}"
                           @delegator_obj.options = policy
                           policy
                       end
            on_event :raw_data,&block
        end

        private
        def process_event(event_name,*args)
            @raw_last_sample = args.first if event_name == :raw_data
            super
        end
    end

    class SubPortProxy < DelegateClass(PortProxy)
        def initialize(port_proxy,subfield = Array.new)
            super(port_proxy)
            @subfield = Array(subfield).map do |field|
                if field.respond_to?(:to_i) && field.to_i.to_s == field
                    field.to_i
                else
                    field
                end
            end
        end

        def to_async(options=Hash.new)
            task.to_async(options).port(port.name,:subfield => @subfield)
        end

        def to_proxy(options=Hash.new)
            self
        end

        def on_data(policy = Hash.new)
            on_raw_data(policy) do |sample|
                sample = Typelib.to_ruby(sample) if sample
                yield(sample)
            end
        end

        def on_raw_data(policy = Hash.new,&block)
            p = proc do |sample|
                block.call subfield(sample,@subfield)
            end
            super(policy,&p)
        end

        def type_name
            type.name
        end

        def full_name
            super + "." + @subfield.join(".")
        end

        def name
            super + "." + @subfield.join(".")
        end

        def orocos_type_name
            type.name
        end

        def new_sample
            type.new
        end

        def last_sample
            subfield(__getobj__.last_sample,@subfield)
        end

        def raw_last_sample
            subfield(__getobj__.raw_last_sample,@subfield)
        end

        def sub_port(subfield)
            raise RuntimeError , "Port #{name} is not an output port" if !output?
            SubPortProxy.new(__getobj__,@subfield+subfield)
        end

        def type
            @sub_type ||= if !@subfield.empty?
                          type ||= super
                          @subfield.each do |f|
                              type = if type.respond_to? :deference
                                         type.deference
                                     else
                                         type[f]
                                     end
                          end
                          type
                      else
                          super
                      end
        end

        private
        def subfield(sample,field)
            return unless sample
            field.each do |f|
                f = if f.is_a? Symbol
                        f.to_s
                    else
                        f
                    end
                sample = if !f.is_a?(Fixnum) || sample.size > f
                             sample.raw_get(f)
                         else
                             #if the field name is wrong typelib will raise an ArgumentError
                             Vizkit.warn "Cannot extract subfield for port #{full_name}: Subfield #{f} does not exist (out of index)!"
                             nil
                         end
                return nil unless sample
            end
            #check if the type is right
            if(sample.class != type)
                raise "Type miss match. Expected type #{type} but got #{sample.class} for subfield #{field.join(".")} of port #{full_name}"
            end
            sample
        end
    end

    class TaskContextProxy < ObjectBase
        attr_reader :name_service
        include Orocos::Namespace
        define_events :port_reachable,
                      :port_unreachable,
                      :property_reachable,
                      :property_unreachable,
                      :attribute_reachable,
                      :attribute_unreachable,
                      :state_change

        # forward methods to designated object
        extend Forwardable
        methods = Orocos::TaskContext.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
        methods << :type
        methods -= TaskContextProxy.instance_methods + [:method_missing,:reachable?,:port]
        def_delegators :@delegator_obj,*methods

        def initialize(name, options = {})
            @options, @task_options = Kernel.filter_options(
                options,
                {
                    name_service: Orocos::Async.name_service,
                    event_loop: Orocos::Async.event_loop,
                    reconnect: true,
                    retry_period: Orocos::Async::TaskContextBase.default_period,
                    use: nil,
                    raise: false,
                    wait: nil
                }
            )

            @name_service = @options[:name_service]
            self.namespace,name = split_name(name)
            self.namespace ||= @name_service.namespace
            super(name,@options[:event_loop])

            @task_options[:event_loop] = @event_loop
            @mutex = Mutex.new
            @ports = {}
            @attributes = {}
            @properties = {}

            get_in_progress = false
            @resolve_timer = @event_loop.every(@options[:retry_period], false) do
                unless get_in_progress
                    get_in_progress = true
                    @name_service.get(self.name, @task_options) do |task_context, error|
                        get_in_progress = false
                        process_resolved_task_context(task_context, error)
                    end
                end
            end
            @resolve_timer.doc = "#{name} reconnect"

            on_port_reachable(false) do |port_name|
                object_reachable_handler(@ports, port_name, "port")
            end
            on_property_reachable(false) do |property_name|
                object_reachable_handler(@properties, property_name, "property")
            end
            on_attribute_reachable(false) do |attribute_name|
                object_reachable_handler(@attributes, attribute_name, "attribute")
            end

            if @options[:use]
                reachable!(@options[:use])
            else
                reconnect(@options[:wait])
            end
        end

        def process_resolved_task_context(task_context, error)
            if error
                case error
                when Orocos::NotFound, Orocos::ComError
                    raise error if @options[:raise]

                    return
                else
                    raise error
                end
            end

            @resolve_timer.stop
            unless task_context.respond_to?(:event_loop)
                raise "TaskProxy is using a name service#{@name_service} "\
                        "which is returning #{task_context.class} but "\
                        "Async::TaskContext was expected."
            end

            task_context.reachable? do |_, e|
                if e
                    @resolve_timer.start
                else
                    reachable!(task_context)
                end
            end
        end

        def name
            map_to_namespace(@name)
        end

        def basename
            @name
        end

        def to_async(options=Hash.new)
            Orocos::Async.get(name,options)
        end

        def to_proxy(options=Hash.new)
            self
        end

        def to_ruby
            TaskContextBase::to_ruby(self)
        end

        # asychronsosly tries to connect to the remote task
        def reconnect(wait_for_task = false)
            @resolve_timer.start options[:retry_period]
            wait if wait_for_task == true
        end

        main_thread_call def property(name, options = Hash.new)
            name = name.to_str
            options,other_options = Kernel.filter_options options, wait: @options[:wait]
            wait if options[:wait]

            p = (@properties[name] ||= PropertyProxy.new(self,name,other_options))

            if other_options.has_key?(:type) && p.type? && other_options[:type] == p.type
                other_options.delete(:type)
            end

            if !other_options.empty? && p.options != other_options
                Orocos.warn "Property #{p.full_name}: is already initialized "\
                            "with options: #{p.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            return p if !valid_delegator? || p.valid_delegator?

            connect_property(p)
            p.wait if options[:wait]
            p
        end

        main_thread_call def attribute(name,options = Hash.new)
            name = name.to_str
            options,other_options = Kernel.filter_options options,:wait => @options[:wait]
            wait if options[:wait]

            a = (@attributes[name] ||= AttributeProxy.new(self,name,other_options))

            if other_options.has_key?(:type) && a.type? && other_options[:type] == a.type
                other_options.delete(:type)
            end

            if !other_options.empty? && a.options != other_options
                Orocos.warn "Attribute #{a.full_name}: is already initialized with options: #{a.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            return a if !valid_delegator? || a.valid_delegator?

            connect_attribute(a)
            a.wait if options[:wait]
            a
        end

        main_thread_call def port(name, options = Hash.new, &callback)
            name = name.to_str
            options,other_options = Kernel.filter_options(
                options, wait: @options[:wait]
            )
            wait if options[:wait]

            # support for subports
            fields = name.split(".")
            name = if fields.empty?
                       name
                   elsif name[0] == "/"
                       # special case for log ports like: logger_name.port("/task_name.port_name")
                       fields = []
                       name
                   else
                       fields.shift
                   end
            type = if !fields.empty?
                       other_options.delete(:type)
                   else
                       nil
                   end

            p = (@ports[name] ||= PortProxy.new(self,name,other_options))

            if other_options.has_key?(:type) && p.type? && other_options[:type] == p.type
                other_options.delete(:type)
            end

            if !other_options.empty? && p.options != other_options
                Orocos.warn "Port #{p.full_name}: is already initialized with options: #{p.options}"
                Orocos.warn "ignoring options: #{other_options}"
            end

            if valid_delegator? && !p.valid_delegator?
                connect_port(p)
                p.wait if options[:wait]
            end

            if fields.empty?
                p
            else
                p.sub_port(fields)
            end
        end

        def ports
            if block_given?
                yield(@ports.values)
            else
                @ports.values
            end
        end

        def properties
            if block_given?
                yield(@properties.values)
            else
                @properties.values
            end
        end

        def attributes
            if block_given?
                yield(@attributes.values)
            else
                @attributes.values
            end
        end

        # call-seq:
        #  task.each_property { |a| ... } => task
        #
        # Enumerates the properties that are available on
        # this task, as instances of Orocos::Attribute
        def each_property(&block)
            @properties.each_value(&block)
        end

        # call-seq:
        #  task.each_attribute { |a| ... } => task
        #
        # Enumerates the attributes that are available on
        # this task, as instances of Orocos::Attribute
        def each_attribute(&block)
            @attributes.each_value(&block)
        end

        # call-seq:
        #  task.each_port { |p| ... } => task
        #
        # Enumerates the ports that are available on this task, as instances of
        # either Orocos::InputPort or Orocos::OutputPort
        def each_port(&block)
            @ports.each_value(&block)
        end

        def reachable!(task_context, options = Hash.new)
            if task_context.kind_of?(TaskContextProxy)
                raise ArgumentError,
                      "task_context must not be instance of TaskContextProxy"
            elsif !task_context.respond_to?(:event_names)
                raise ArgumentError,
                      "task_context must be an async instance, got #{task_context.class}"
            end

            @last_task_class ||= task_context.class
            if @last_task_class != task_context.class
                Orocos.warn "Class mismatch: TaskContextProxy #{name} was recently "\
                            "connected to #{@last_task_class} and is now connected "\
                            "to #{task_context.class}."
                @last_task_class = task_context.class
            end

            if valid_delegator?
                remove_proxy_event(@delegator_obj, @delegator_obj.event_names)
            end

            if @delegator_obj_old
                remove_proxy_event(@delegator_obj_old, @delegator_obj_old.event_names)
                @delegator_obj_old = nil
            end

            super(task_context, options)

            # this is emitting on_port_reachable, on_property_reachable ....
            proxy_event(@delegator_obj, @delegator_obj.
                        event_names - [:reachable, :unreachable])

            @delegator_obj.on_unreachable do
                unreachable!
            end
        end

        def reachable?
            @mutex.synchronize do
                super && @delegator_obj.reachable?
            end
        rescue Orocos::NotFound => e
            unreachable! error: e, reconnect: @options[:reconnect]
            false
        end

        def unreachable!(options = {})
            return unless valid_delegator?

            Kernel.validate_options options, :reconnect, :error
            @delegator_obj_old =
                @mutex.synchronize do
                    # do not stop proxing events here (see reachable!)
                    # otherwise unrechable event might get lost
                    if valid_delegator?
                        @delegator_obj
                    else
                        @delegator_obj_old
                    end
                end

            super(options)
            disconnect_ports
            disconnect_attributes
            disconnect_properties
            reconnect if options.fetch(:reconnect, @options[:reconnect])
        end

        private

        def connect_async_object(object, callback)
            delegator_obj = @delegator_obj
            return unless delegator_obj

            finalizer = lambda do |resolved, _error|
                object.reachable!(resolved) if resolved && !object.valid_delegator?
                callback&.call(object)
            end

            # called in the context of @delegator_obj
            begin
                yield(delegator_obj, finalizer) # this is yield(@delegator_obj)
            rescue Orocos::NotFound
                Orocos.warn "task #{name} has currently no port called #{port.name}"
                raise
            rescue Orocos::CORBA::ComError => e
                Orocos.warn "task #{name} with error on port: #{port.name} -- #{e}"
                raise
            end
        end

        # blocking call shoud be called from a different thread
        # all private methods must be thread safe
        main_thread_call def connect_port(port, &callback)
            connect_async_object(port, callback) do |delegator_obj, finalizer|
                delegator_obj.port(port.name, true, port.options, &finalizer)
            end
        end

        main_thread_call def disconnect_ports
            ports = @mutex.synchronize { @ports.values.dup }
            ports.each(&:unreachable!)
        end

        # blocking call shoud be called from a different thread
        main_thread_call def connect_attribute(attribute, &callback)
            connect_async_object(attribute, callback) do |delegator_obj, finalizer|
                delegator_obj.attribute(attribute.name, attribute.options, &finalizer)
            end
        end

        main_thread_call def disconnect_attributes
            attributes = @mutex.synchronize { @attributes.values.dup }
            attributes.each(&:unreachable!)
        end

        # blocking call shoud be called from a different thread
        main_thread_call def connect_property(property, &callback)
            connect_async_object(property, callback) do |delegator_obj, finalizer|
                delegator_obj.property(property.name, property.options, &finalizer)
            end
        end

        main_thread_call def disconnect_properties
            @mutex.synchronize { pp @properties.keys }
            properties = @mutex.synchronize { @properties.values.dup }
            properties.each(&:unreachable!)
        end

        def respond_to_missing?(method_name, include_private = false)
            @delegator_obj.respond_to?(method_name) || super
        end

        def method_missing(m, *args)
            return super unless respond_to_missing?(m)

            event_loop.sync(@delegator_obj, args) do |_args|
                @delegator_obj.method(m).call(*args)
            end
        end

        def object_reachable_handler(map, name, type)
            obj = map[name]
            return unless valid_delegator?
            return if !obj || obj.valid_delegator?

            send("connect_#{type}", obj)
        end
    end
end
