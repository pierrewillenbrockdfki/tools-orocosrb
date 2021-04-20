module Orocos::Async::CORBA
    class OutputReader < Orocos::Async::ObjectBase
        extend Utilrb::EventLoop::Forwardable
        extend Orocos::Async::ObjectBase::Periodic::ClassMethods
        include Orocos::Async::ObjectBase::Periodic

        define_events :data,:raw_data
        attr_reader :policy
        attr_reader :raw_last_sample

        attr_reader :period

        # The event loop timer that is polling the connection
        attr_reader :poll_timer

        self.default_period = 0.1

        # @param [Async::OutputPort] port The Asyn::OutputPort
        # @param [Orocos::OutputReader] reader The designated reader
        def initialize(port, reader, period: default_period)
            super(port.name,port.event_loop)
            @port = port
            @raw_last_sample = nil
            @policy = reader.policy
            @period = period

            timeout =
                if reader.policy[:type] == :buffer
                    period
                else 0
                end

            poll_timer = @event_loop.async_every(
                method(:thread_read),
                Hash[period: period,
                     start: false,
                     known_errors: Orocos::Async::KNOWN_ERRORS],
                timeout, &method(:thread_read_callback))
            poll_timer.doc = port.full_name
            @poll_timer = poll_timer

            # otherwise event reachable will be queued and all 
            # listeners will be called twice (one for registering and one because
            # of the queued event)
            disable_emitting do
                reachable! reader
            end
            proxy_event @port,:unreachable
        rescue Orocos::NotFound => e
            emit_error e
        end

        def last_sample
            if @raw_last_sample
                Typelib.to_ruby(@raw_last_sample)
            end
        end

        # TODO keep timer and remote connection in mind
        def unreachable!(options = Hash.new)
            poll_timer.cancel
            @raw_last_sample = nil

            # ensure that this is always called from the
            # event loop thread
            @event_loop.call do
                old = begin
                          @delegator_obj.disconnect if valid_delegator?
                      rescue Orocos::ComError,Orocos::NotFound => e
                      ensure
                          if valid_delegator?
                              event :unreachable
                              @delegator_obj
                          end
                      end
                super
                old
            end
        end

        def reachable?
            super && @port.reachable?
        end

        def reachable!(reader,options = Hash.new)
            super
            if number_of_listeners(:data) != 0
                poll_timer.start period unless poll_timer.running?
            end
        end

        def period=(period)
            super
            poll_timer.period = self.period
        end

        def really_add_listener(listener)
            if listener.event == :data
                poll_timer.start(period) unless poll_timer.running?
                listener.call Typelib.to_ruby(@raw_last_sample) if @raw_last_sample && listener.use_last_value?
            elsif listener.event == :raw_data
                poll_timer.start(period) unless poll_timer.running?
                listener.call @raw_last_sample if @raw_last_sample && listener.use_last_value?
            end
            super
        end

        def remove_listener(listener)
            super
            if number_of_listeners(:data) == 0 && number_of_listeners(:raw_data) == 0
                poll_timer.cancel
            end
        end

        private

        # blocking method called from thread pool to read new data
        def thread_read(timeout)
            deadline = Time.now + timeout
            raw_last_sample = nil
            while data = raw_read_new # sync call from bg thread
                raw_last_sample = data
                event :raw_data, data
                # TODO just emit raw_data and convert it to ruby
                # if someone is listening to (see PortProxy)
                event(:data) { [Typelib.to_ruby(data)] }
                break if Time.now > deadline
            end
            raw_last_sample
        end

        # callback after thread_read returns called from the main thread
        def thread_read_callback(data, error)
            if data
                @raw_last_sample = data
            elsif error
                poll_timer.cancel
                self.period = poll_timer.period
                @event_loop.once do
                    event :error,error
                end
            end
        end

        forward_to :@delegator_obj,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error  do
            methods = Orocos::OutputReader.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::OutputReader.instance_methods
            methods << :type
            def_delegators methods
        end
    end

    class InputWriter < Orocos::Async::ObjectBase
        extend Utilrb::EventLoop::Forwardable

        def initialize(port,writer,options=Hash.new)
            super(port.name,port.event_loop)
            @port = port
            disable_emitting do
                reachable!(writer)
            end
        end

        def unreachable!(options = Hash.new)
            @delegator_obj.disconnect if valid_delegator?
            super
        end

        private
        forward_to :@delegator_obj,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :emit_error  do
            methods = Orocos::InputWriter.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::InputWriter.instance_methods
            methods << :type
            def_delegators methods
        end
    end

    class Port < Orocos::Async::ObjectBase
        extend Utilrb::EventLoop::Forwardable
        attr_accessor :options

        def task
            @task
        end

        def reachable!(port,options = Hash.new)
            @mutex.synchronize do
                super
            end
        end

        def unreachable!(options = Hash.new)
            @mutex.synchronize do
                super
            end
        end

        def reachable?
            super && @task.reachable?
        end

        def to_async(options=Hash.new)
            self
        end

        def to_proxy(options=Hash.new)
            task.to_proxy(options).port(name)
        end

        protected

        def initialize(async_task,port,options=Hash.new)
            raise ArgumentError, "no task is given" unless async_task
            raise ArgumentError, "no port is given" unless port
            @options ||= options
            @task ||= async_task
            @mutex ||= Mutex.new
            super(port.name,async_task.event_loop)
            @task.on_unreachable do
                unreachable!
            end
            disable_emitting do
                reachable!(port)
            end
        end

        def connection_error(error)
            emit_error error
        end

        def port
            @mutex.synchronize do 
                if !valid_delegator?
                    error = Orocos::NotFound.new "Port #{name} is not reachable"
                    [nil,error]
                else
                    @delegator_obj
                end
            end
        end
    end

    class OutputPort < Port
        define_events :data,:raw_data

        def initialize(async_task,port,options=Hash.new)
            super
            @readers = Array.new
        end

        def last_sample
            @global_reader.last_sample if @global_reader
        end

        def raw_last_sample
            @global_reader.raw_last_sample if @global_reader
        end

        def options=(options)
            super
            @global_reader = nil
        end

        def reader(options = Hash.new,&block)
            options, policy = Kernel.filter_options options, :period => nil
            policy[:init] = true unless policy.has_key?(:init)
            policy[:pull] = true unless policy.has_key?(:pull)
            if block
                orig_reader(policy) do |reader,error|
                    unless error
                        reader = OutputReader.new(self,reader,options)
                        proxy_event(reader,:error)
                    end
                    if block.arity == 2
                        block.call(reader,error)
                    elsif !error
                        block.call(reader)
                    end
                end
            else
                reader = OutputReader.new(self,orig_reader(policy),options)
                proxy_event(reader,:error)
                reader
            end
        end

        def on_data(policy = Hash.new,&block)
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !@global_reader
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "Changing global reader policy for #{full_name} from #{@options} to #{policy}"
                           self.options = @options
                           @options
                       end
            on_event :data,&block
        end

        def on_raw_data(policy = Hash.new,&block)
            @options = if policy.empty?
                           @options
                       elsif @options.empty? && !@global_reader
                           policy
                       elsif @options == policy
                           @options
                       else
                           Orocos.warn "Changing global reader policy for #{full_name} from #{@options} to #{policy}"
                           self.options = @options
                           @options
                       end
            on_event :raw_data,&block
        end

        def period=(value)
            @period = value
            @global_reader.period = value if @global_reader.respond_to?(:period=)
        end

        def really_add_listener(listener)
            super
            if listener.event == :data
                if @global_reader
                    if listener.use_last_value?
                        if sample = @global_reader.last_sample
                            listener.call sample
                        end
                    end
                end
            elsif listener.event == :raw_data
                if @global_reader
                    if listener.use_last_value?
                        if sample = @global_reader.raw_last_sample
                            listener.call sample
                        end
                    end
                end
            end
        end

        def add_listener(listener)
            super
            if((listener.event == :data || listener.event == :raw_data) && !@global_reader)
                # Errors during reader creation are reported on the port. Do
                # #on_error on the port to get them
                reader(@options) do |reader|
                    if @global_reader
                        # We created multiple readers because of concurrency.
                        # Just ignore this one
                        reader.disconnect
                    elsif number_of_listeners(:data) > 0 || number_of_listeners(:raw_data) > 0  # The listener might already have been removed !
                        @global_reader = reader
                        proxy_event(reader,:data,:raw_data)
                        @global_reader.period = @options[:period] if @options.has_key? :period
                    end
                end
            end
        end

        def remove_listener(listener)
            super
            if number_of_listeners(:data) == 0  && number_of_listeners(:raw_data) == 0 && @global_reader&.valid_delegator?
                remove_proxy_event(@global_reader)
                @global_reader.disconnect{} # call it asynchron
                @global_reader = nil
            end
        end

        def unreachable!(options = Hash.new)
            if @global_reader.respond_to?(:unreachable!)
                @global_reader.unreachable! 
            end
            super
        end

        def reachable!(port,options = Hash.new)
            super
            if @global_reader
                orig_reader(@global_reader.policy) do |reader,error|
                    unless error
                        @global_reader.reachable!(reader)
                    end
                end
            end
        end

        forward_to :port,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :connection_error do
            methods = Orocos::OutputPort.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::OutputPort.instance_methods
            methods << :type
            def_delegators methods
            def_delegator :reader, :alias => :orig_reader
            def_delegator :read, :alias => :orig_read
        end
    end

    class InputPort < Port
        def initialize(*args)
            super
            @write_blocks = []
        end

        def writer(options = Hash.new,&block)
            if block
                orig_writer(options) do |writer,error|
                    unless error
                        writer = InputWriter.new(self,writer)
                        proxy_event(writer,:error)
                    end
                    if block.arity == 2
                        block.call(writer,error)
                    elsif !error
                        block.call(writer)
                    end
                end
            else
                writer = InputWriter.new(self,orig_writer(options))
                proxy_event(writer,:error)
                writer
            end
        end

        def reachable!(port,options = Hash.new)
            super
            #TODO we have to call reachable on all writer
            if @global_writer
                orig_writer(@global_writer.policy) do |writer,error|
                    unless error
                        @global_writer.reachable!(writer)
                    end
                end
            end
        end

        def options=(options)
            super
            @global_writer = nil
        end

        def write(sample,options=@options,&block)
            if @options != options
                Orocos.warn "Changing global writer policy for #{full_name} from #{@options} to #{options}" unless @options.empty?
                self.options = options
            end
            if block
                if @global_writer.respond_to? :write
                    @global_writer.write(sample) do |result,error|
                        if block.arity == 2
                            block.call result,error
                        elsif !error
                            block.call result
                        end
                    end
                # writer is requested waiting for writer obj
                elsif @global_writer
                    # store code block until writer is obtained
                    @write_blocks << [block,sample]
                    @global_writer
                # create new global writer
                else
                    @write_blocks << [block,sample]
                    @global_writer ||= writer(@options) do |writer,error|
                        if error
                            block.call result,error if block.arity == 2
                        else
                            @global_writer = writer # overwrites @global_writer before that it is a ThreadPool::Task
                            @global_writer.period = @options[:period] if @options.has_key? :period
                            @write_blocks.each do |b,s|
                                write(s,&b)
                            end
                            @write_blocks = []
                        end
                    end
                end
            else
                raise NotImplementedError, "Async::InputPort#write(sample) not implemented, provide a completion block as e.g. port.write(sample) { }"
            end
        end

        forward_to :port,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :connection_error  do
            methods = Orocos::InputPort.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::InputPort.instance_methods
            methods << :type
            def_delegators methods
            def_delegator :writer, :alias => :orig_writer
        end
    end
end
