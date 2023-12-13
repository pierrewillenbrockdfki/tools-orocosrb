module Orocos
    module PortBase
        # The task this port is part of
        attr_reader :task
        # The port name
        attr_reader :name
        # The port full name. It is task_name.port_name
        def full_name; "#{task.name}.#{name}" end
        # The port's type name as used by the RTT
        attr_reader :orocos_type_name
        # The port's type as a Typelib::Type object
        attr_reader :type
        # The port's model
        # @return [OroGen::Spec::Port,nil] the port model
        attr_reader :model

        def initialize(task, name, orocos_type_name, model)
            @task = task
            @name = name
            @orocos_type_name = orocos_type_name
            @model = model

            ensure_type_available(:fallback_to_null_type => true)

            if model
                @max_sizes = model.max_sizes.dup
            else
                @max_sizes = Hash.new
            end
            @max_sizes.merge!(Orocos.max_sizes_for(type))

            super() if defined? super
        end

        D_UNKNOWN      = 0
        D_SAME_PROCESS = 1
        D_SAME_HOST    = 2
        D_DIFFERENT_HOSTS   = 3

        # How "far" from the given input port this port is
        #
        # @return one of the D_ constants
        def distance_to(input_port)
            if !task.process || !input_port.task.process
                return D_UNKNOWN
            elsif task.process == input_port.task.process
                return D_SAME_PROCESS
            elsif task.process.host_id == input_port.task.process.host_id
                return D_SAME_HOST
            else return D_DIFFERENT_HOSTS
            end
        end

        def to_s
            "#{full_name}"
        end

        # True if +self+ and +other+ represent the same port
        def ==(other)
            return false if !other.kind_of?(PortBase)
            other.task == self.task && other.name == self.name
        end

        def ensure_type_available(options = Hash.new)
            if !type || type.null?
                @type = Orocos.find_type_by_orocos_type_name(orocos_type_name, **options)
            end
        end

        # Returns a new object of this port's type
        def new_sample
            ensure_type_available
            @type.new
        end

        def log_metadata
            metadata = Hash['rock_task_model' => (task.model.name || ''),
                'rock_task_name' => task.name,
                'rock_task_object_name' => name,
                'rock_stream_type' => 'port',
                'rock_orocos_type_name' => orocos_type_name,
                'rock_cxx_type_name' => orocos_type_name]

	    if Orocos.logger_guess_timestamp_field?
		# see if we can find a time field in the type, which
		# would qualify as being used as the default time stamp
		if @type.respond_to? :each_field
		    @type.each_field do |name, type|
			if type.name == "/base/Time"
			    metadata['rock_timestamp_field'] = name
			    break
			end
		    end
		else
		    # TODO what about if the type is a base::Time itself
		end
	    end

	    metadata
        end

        # @overload max_sizes('name.to[].field' => value, 'name.other' => value) => self
        #   Sets the maximum allowed size for the variable-size containers in
        #   +type+. If the type is a compound, the mapping is given as
        #   path.to.field => size. If it is a container, the size of the
        #   container itself is given as first argument, and the sizes for the
        #   contained values as a second map argument.
        #
        #   For instance, with the types
        #
        #     struct A
        #     {
        #         std::vector<int> values;
        #     };
        #     struct B
        #     {
        #         std::vector<A> field;
        #     };
        #
        #   Then sizes on a port of type B would be given with
        #
        #     port.max_sizes('field' => 10, 'field[].values' => 20)
        #
        #   while the sizes on a port of type std::vector<A> would be given
        #   with
        #
        #     port.max_sizes(10, 'values' => 20)
        #
        # @overload max_sizes => current size specification
        #
        dsl_attribute :max_sizes do |*values|
            # Validate that all values are integers and all names map to
            # known types
            value = OroGen::Spec::OutputPort.validate_max_sizes_spec(type, values)
            max_sizes.merge(value)
        end

        # Returns the maximum marshalled size of a sample from this port, as
        # marshalled by typelib
        #
        # If the type contains variable-size containers, the result is dependent
        # on the values given to #max_sizes. If not enough is known, this method
        # will return nil.
        def max_marshalling_size
            OroGen::Spec::OutputPort.compute_max_marshalling_size(type, max_sizes)
        end
    end

    # Generic implementation of some methods for all input-port-like objects
    #
    # For #reader to work, the mixed-in class must provide a writer_class
    # singleton method, and must be able to connect to an input port
    module InputPortBase
        # For convenience, automatically reverts the connection direction
        def connect_to(other, policy = Hash.new)
            if other.respond_to?(:writer) # This is also an input port !
                raise ArgumentError, "cannot connect #{self} with #{other}, as they are both inputs"
            end
            other.connect_to(self, policy)
        end

        # Returns a InputWriter object that allows you to write data to the
        # remote input port.
        def writer(distance: PortBase::D_UNKNOWN, **policy)
            ensure_type_available
            writer = Orocos.ruby_task_access do
                Orocos.ruby_task.create_output_port(
                    self.class.transient_local_port_name(full_name),
                    orocos_type_name,
                    permanent: false,
                    class: self.class.writer_class) 
            end
            writer.port = self
            writer.policy = policy
            writer.connect_to(self, distance: distance, **policy)
            writer
        end

        # Writes one sample with a default policy.
        #
        # While convenient, this is quite ressource consuming, as each time one
        # will need to create a new connection between the ruby interpreter and
        # the remote component.
        #
        # Use #writer if you need to write on the same port repeatedly.
        def write(sample)
            writer.write(sample)
        end

        # This method is part of the connection protocol
        #
        # Whenever an output is connected to an input, if the receiver
        # object cannot resolve the connection, it calls
        # #resolve_connection_from on its target
        #
        # @param source the source object in the connection that is being
        #   created
        # @raise [ArgumentError] if the connection cannot be created
        def resolve_connection_from(source, policy = Hash.new)
            raise ArgumentError, "I don't know how to connect #{source} to #{self}"
        end

        # This method is part of the connection protocol
        #
        # Whenever an output is disconnected from an input, if the receiver
        # object cannot resolve the connection, it calls
        # #resolve_disconnection_from on its target
        #
        # @param source the source object in the connection that is being
        #   destroyed
        # @raise [ArgumentError] if the connection cannot be undone (or if it
        #   could not exist in the first place)
        def resolve_disconnection_from(source)
            raise ArgumentError, "I don't know how to disconnect #{source} to #{self}"
        end
    end

    # Generic functionality for all output objects
    #
    # For {#reader} to work, the mixed-in class must provide a reader_class
    # singleton method, and must be able to connect to an input port
    #
    # It also implements the fallback calls for the connection / disconnection
    # protocol. Any 'output port' class must call this generic implementation
    # when it does not know how to connect to / disconnect from the argument it
    # has been given. The 'input port' classes that can handle specialized
    # connection schemes must then implement #resolve_connection_from and
    # #resolve_disconnection_from to implement them. These methods are called by
    # the default implementation of #connect_to and #disconnect_from.
    module OutputPortBase
        # Returns an OutputReader object that is connected to that port
        #
        # The policy dictates how data should flow between the port and the
        # reader object. See #prepare_policy
        def reader(distance: PortBase::D_UNKNOWN, **policy)
            ensure_type_available
            reader = Orocos.ruby_task_access do
                Orocos.ruby_task.create_input_port(
                    self.class.transient_local_port_name(full_name),
                    orocos_type_name,
                    permanent: false,
                    class: self.class.reader_class)
            end
            reader.port = self
            reader.policy = policy
            connect_to(reader, distance: distance, **policy)
            reader
        end

        # Generic implementation of #connect_to
        #
        # It calls #resolve_connection_from, as a fallback for
        # out.connect_to(in) calls where 'out' does not know how to handle 'in'
        def connect_to(sink, policy = Hash.new)
            sink.resolve_connection_from(self, policy)
        end

        # Generic implementation of #disconnect_from
        #
        # It calls #resolve_connection_from, as a fallback for
        # out.connect_to(in) calls where 'out' does not know how to handle 'in'
        def disconnect_from(sink)
            sink.resolve_disconnection_from(self)
        end
    end

end


