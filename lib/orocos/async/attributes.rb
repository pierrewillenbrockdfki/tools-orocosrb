
module Orocos::Async::CORBA
    class AttributeBase < Orocos::Async::ObjectBase
        extend Utilrb::EventLoop::Forwardable
        extend Orocos::Async::ObjectBase::Periodic::ClassMethods
        include Orocos::Async::ObjectBase::Periodic

        define_events :change,:raw_change
        attr_reader :raw_last_sample

        def initialize(async_task,attribute,options=Hash.new)
            super(attribute.name,async_task.event_loop)
            @options = Kernel.validate_options options, :period => default_period
            @task = async_task
            @mutex = Mutex.new

            disable_emitting do
                reachable!(attribute)
            end

            @poll_timer = @event_loop.async_every(
                proc { @delegator_obj.raw_read },
                { period: period, start: false,
                  known_errors: Orocos::Async::KNOWN_ERRORS }
            ) do |data, error|
                if error
                    @poll_timer.cancel
                    self.period = @poll_timer.period
                    event :error, error
                elsif data
                    if @raw_last_sample != data
                        @raw_last_sample = data
                        event :raw_change, data
                        event :change, Typelib.to_ruby(data)
                    end
                end
            end
            @poll_timer.doc = attribute.full_name

            @task.on_unreachable do
                unreachable!
            end
        rescue Orocos::NotFound => e
            emit_error e
        end

        def last_sample
            if @raw_last_sample
                Typelib.to_ruby(@raw_last_sample)
            end
        end

        def unreachable!(options = Hash.new)
            super
            @raw_last_sample = nil
            @poll_timer.cancel
        end

        def reachable!(attribute,options = Hash.new)
            super
            @raw_last_sample = nil
        end

        def reachable?
            super && @raw_last_sample
        end

        def period=(period)
            super
            @poll_timer.period = self.period
        end

        # waits until object gets reachable raises Orocos::NotFound if the
        # object was not reachable after the given time spawn
        def wait(timeout = 5.0)
            # make sure the poll timer is running otherwise wait
            # will always fail
            poll_timer_running  = @poll_timer.running?
            @poll_timer.start(0.01) unless poll_timer_running
            time = Time.now
            @event_loop.wait_for do
                if timeout && timeout <= Time.now-time
                    Utilrb::EventLoop.cleanup_backtrace do
                        raise Orocos::NotFound,"#{self.class}: #{respond_to?(:full_name) ? full_name : name} is not reachable after #{timeout} seconds"
                    end
                end
                reachable?
            end
            @poll_timer.stop unless poll_timer_running
            self
        end

        def really_add_listener(listener)
            super
            if listener.event == :raw_change
                @poll_timer.start(period) unless @poll_timer.running?
                listener.call(@raw_last_sample) if @raw_last_sample && listener.use_last_value?
            elsif listener.event == :change
                @poll_timer.start(period) unless @poll_timer.running?
                listener.call(Typelib.to_ruby(@raw_last_sample)) if @raw_last_sample && listener.use_last_value?
            end
        end

        def remove_listener(listener)
            super
            if number_of_listeners(:change) == 0
                if @poll_timer.running?
                    @poll_timer.stop
                end
                @policy = nil
            end
        end

        def on_raw_change(policy = Hash.new,&block)
            @policy = if policy.empty?
                           options
                       elsif !@policy
                           policy
                       elsif @policy == policy
                           @policy
                       else
                           Orocos.warn "Property #{full_name} cannot emit :raw_change with different policies."
                           Orocos.warn "The current policy is: #{@policy}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @policy
                       end
            on_event :raw_change,&block
        end

        def on_change(policy = Hash.new,&block)
            @policy = if policy.empty?
                           options
                       elsif !@policy
                           policy
                       elsif @policy == policy
                           @policy
                       else
                           Orocos.warn "Property #{full_name} cannot emit :change with different policies."
                           Orocos.warn "The current policy is: #{@policy}."
                           Orocos.warn "Ignoring policy: #{policy}."
                           @policy
                       end
            on_event :change,&block
        end

        private
        forward_to :attribute,:@event_loop,:known_errors => Orocos::Async::KNOWN_ERRORS,:on_error => :connection_error  do
            methods = Orocos::AttributeBase.instance_methods.find_all{|method| nil == (method.to_s =~ /^do.*/)}
            methods -= Orocos::Async::CORBA::AttributeBase.instance_methods
            methods << :type
            def_delegators methods
        end

        def connection_error(error)
            unreachable!(:error => error)
            emit_error error
        end

        def attribute
            @mutex.synchronize do
                if !valid_delegator?
                    error = Orocos::NotFound.new "#{self.class.name} #{name} is not reachable"
                    [nil,error]
                else
                    @delegator_obj
                end
            end
        end
    end

    class Property < AttributeBase
        self.default_period = 1.0
    end

    class Attribute < AttributeBase
        self.default_period = 1.0
    end
end
