module Orocos::Async
    class EventListener
        attr_reader :event
        attr_reader :last_args

        def initialize(obj, event, use_last_value = true, &block)
            raise ArgumentError, "no object given" unless obj

            @block = block
            @obj = obj
            @event = event
            @use_last_value = use_last_value
        end

        # returns true if the listener shall be called
        # with the last available value when started
        def use_last_value?
            !!@use_last_value
        end

        def pretty_print(pp) # :nodoc:
            pp.text "EventListener #{@event}"
        end

        # stop listing to the event
        def stop
            @last_args = nil
            @obj.remove_listener(self)
            self
        end

        # start listing  to the event
        def start(use_last_value = @use_last_value)
            @use_last_value = use_last_value
            @obj.add_listener(self)
            self
        end

        # Whether the listener is currently started
        def listening?
            @obj.listener?(self)
        end

        # calls the callback
        def call(*args)
            @last_args = args
            @block.call *args
        end
    end

    # Null object for the delegated object in ObjectBase
    class DelegatorDummy
        attr_reader :event_loop
        attr_reader :name

        def initialize(parent,name,event_loop)
            @parent = parent
            @name = name
            @event_loop = event_loop
        end

        def respond_to_missing?(m, _include_private = false)
            true
        end

        def method_missing(m,*args,&block)
            return super if m == :to_ary

            error = Orocos::NotFound.new "#{@name} is not reachable while accessing #{m}"
            error.set_backtrace(Kernel.caller)
            raise error unless block

            @event_loop.defer on_error: @parent.method(:emit_error),
                              callback: block,
                              known_errors: Orocos::Async::KNOWN_ERRORS do
                raise error
            end
        end
    end

    class ObjectBase
        module Periodic
            module ClassMethods
                attr_writer :default_period

                # Returns the default period for all instances of this class. It
                # inherits the value from parent classes
                def default_period
                    if @default_period then @default_period
                    elsif superclass.respond_to?(:default_period)
                        superclass.default_period
                    end
                end
            end

            def default_period
                self.class.default_period
            end

            def period
                @options[:period]
            end

            def period=(value)
                @options[:period]= if value
                                       value
                                   else
                                       default_period
                                   end
            end
        end

        class << self
            def event_names
                @event_names ||= if self != ObjectBase
                                     superclass.event_names.dup
                                 else
                                     []
                                 end
            end

            def define_event(name)
                define_events(name)
            end

            def define_events(*names)
                names.flatten!
                names.each do |n|
                    raise "Cannot add event #{n}. It is already added" if event_names.include? n
                    event_names << n
                    str =  %Q{ def on_#{n}(use_last_value = true,&block)
                                on_event #{n.inspect},use_last_value,&block
                            end
                            def once_on_#{n}(use_last_value = true,&block)
                                l = on_event #{n.inspect},use_last_value do |*args|
                                       block.call(*args)
                                       l.stop
                                    end
                            end
                            def emit_#{n}(*args)
                                event #{n.inspect},*args
                            end }
                    class_eval(str)
                end
            end

            def valid_event?(name)
                event_names.include?(name)
            end

            def validate_event(name)
                name = name.to_sym
                if !valid_event?(name)
                    raise "event #{name} is not emitted by #{self}. The following events are emitted #{event_names.join(", ")}"
                end
                name
            end
        end

        attr_reader :event_loop
        attr_reader :options
        attr_accessor :name
        define_events :error,:reachable,:unreachable

        # Queue of listener that are going to be added by callbacks registered
        # in the event loop. This is filled and processed by #add_listener and
        # #remove_listener
        #
        # Some entries might be nil if #remove_listener has been called before
        # the event loop processed the addition callbacks.
        #
        # @return [Array<EventLoop,nil>]
        attr_reader :pending_adds

        def initialize(name, event_loop)
            raise ArgumentError, "object name cannot be nil" unless name

            @listeners ||= Hash.new{ |hash,key| hash[key] = []}
            @proxy_listeners ||= Hash.new{ |hash,key| hash[key] = {} }
            @name ||= name
            @event_loop ||= event_loop
            @options ||= {}
            @pending_adds = []

            invalidate_delegator!
            on_error do |e|
                unreachable!(error: e) if e.kind_of?(Orocos::ComError)
            end
        end

        def self.main_thread_call(name)
            alias_name = "__main_thread_call_#{name}"
            return if method_defined?(alias_name)

            alias_method alias_name, name
            define_method name do |*args, **kw, &block|
                return send(alias_name, *args, **kw, &block) if @event_loop.thread?

                raise "#{name} called outside of event loop thread"
            end
            name
        end

        def assert_in_event_loop_thread
            @event_loop.validate_thread
        end

        def invalidate_delegator!
            @delegator_obj = DelegatorDummy.new(self, @name, @event_loop)
        end

        def emitting?
            !Thread.current["__#{self}_disable_emitting"]
        end

        # Disable event emission while the block is called
        #
        # This is thread-safe
        def emitting(value, &block)
            old = emitting?
            Thread.current["__#{self}_disable_emitting"] = !value

            instance_eval(&block)
        ensure
            Thread.current["__#{self}_disable_emitting"] = !old
        end

        def disable_emitting(&block)
            emitting(false, &block)
        end

        # Returns true if the event is known
        def valid_event?(event)
            self.class.valid_event?(event)
        end

        def validate_event(event)
            self.class.validate_event(event)
        end

        def event_names
            self.class.event_names
        end

        main_thread_call def on_event(event, use_last_value = true, &block)
            event = validate_event event
            EventListener.new(self, event, use_last_value, &block).start
        end

        # returns the number of listener for the given event
        main_thread_call def number_of_listeners(event)
            event = validate_event event
            @listeners[event].size
        end

        # Returns true if the listener is active
        main_thread_call def listener?(listener)
            @listeners[listener.event].include? listener
        end

        # Returns the listeners for the given event
        main_thread_call def listeners(event)
            event = validate_event event
            @listeners[event]
        end

        # adds a listener to obj and proxies
        # event like it would be emitted from self
        #
        # if no listener is registererd to event it
        # also removes the listener from obj
        main_thread_call def proxy_event(obj,*events)
            return if obj == self

            events = events.flatten
            events.each do |e|
                if existing = @proxy_listeners[obj].delete(e)
                    existing.stop
                end
                l = @proxy_listeners[obj][e] = EventListener.new(obj,e,true) do |*val|
                    process_event e,*val
                end
                l.start if number_of_listeners(e) > 0
            end
        end

        main_thread_call def remove_proxy_event(obj,*events)
            return if obj == self

            events = events.flatten
            if events.empty?
                remove_proxy_event(obj,@proxy_listeners[obj].keys)
                @proxy_listeners.delete(obj)
            else
                events.each do |e|
                    if listener = @proxy_listeners[obj].delete(e)
                        listener.stop
                    end
                end
            end
        end

        main_thread_call def add_listener(listener)
            validate_event(listener.event)
            return listener if pending_adds.include? listener

            pending_adds << listener

            # We queue the addition so that evenst that are currently queued are not
            # given to the new listeners.
            event_loop.once do
                expected = pending_adds.shift
                # 'expected' is nil if the listener has been removed before this
                # block got processed
                if expected
                    if expected != listener
                        raise RuntimeError,
                              "internal error in #{self}#add_listener: "\
                              "pending addition and expected addition mismatch"
                    end
                    really_add_listener(listener)
                end
            end
            listener
        end

        main_thread_call def really_add_listener(listener)
            if listener.use_last_value?
                if listener.event == :reachable
                    listener.call if valid_delegator?
                elsif listener.event == :unreachable
                    listener.call unless valid_delegator?
                end
            end
            @proxy_listeners.each do |obj,listeners|
                if (l = listeners[listener.event])
                    if listener.use_last_value? && !listener.last_args
                        # replay last value if requested
                        obj.really_add_listener(listener)
                        obj.remove_listener(listener)
                    end
                    l.start(false) unless l.listening?
                end
            end
            unless @listeners[listener.event].include?(listener)
                @listeners[listener.event] << listener
            end
            listener
        end

        main_thread_call def remove_listener(listener)
            if (idx = pending_adds.index(listener))
                pending_adds[idx] = nil
            end

            @listeners[listener.event].delete listener

            # Check whether the only listeners left are proxy listeners. If they
            # are, remove them
            if number_of_listeners(listener.event) == 0
                @proxy_listeners.each do |obj, listeners|
                    if l = listeners[listener.event]
                        obj.remove_listener(l)
                    end
                end
            end
        end

        # calls all listener which are registered for the given event
        # the next step
        def event(event_name,*args,&block)
            return unless emitting?

            validate_event event_name
            @event_loop.once do
                process_event event_name, *args, &block
            end
            self
        end

        # waits until object gets reachable raises Orocos::NotFound if the
        # object was not reachable after the given time spawn
        def wait(timeout = 5.0)
            time = Time.now
            @event_loop.wait_for do
                if timeout && timeout <= Time.now-time
                    Utilrb::EventLoop.cleanup_backtrace do
                        name = respond_to?(:full_name) ? full_name : name
                        raise Orocos::NotFound,
                              "#{self.class}: #{name} is not reachable "\
                              "after #{timeout} seconds"
                    end
                end
                valid_delegator?
            end
            self
        end

        main_thread_call def reachable?
            if block_given?
                yield(valid_delegator?)
            else
                valid_delegator?
            end
        end

        main_thread_call def reachable!(obj, _options = {})
            @delegator_obj = obj
            event :reachable if valid_delegator?
        end

        main_thread_call def unreachable!(_options = {})
            return unless valid_delegator?

            invalidate_delegator!
            event :unreachable
        end

        def valid_delegator?
            !@delegator_obj.kind_of?(DelegatorDummy)
        end

        main_thread_call def remove_all_listeners
            @listeners.dup.each_value do |listeners|
                remove_listener(listeners.first) until listeners.empty?
            end
        end

        private

        # calls all listener which are registered for the given event
        main_thread_call def process_event(event_name, *args, &block)
            validate_event(event_name)
            args = block.call if block

            # @listeners have to be cloned because it might get modified
            # by listener.call
            @listeners[event_name].clone.each do |listener|
                listener.call(*args)
            end
            self
        end
    end
end
