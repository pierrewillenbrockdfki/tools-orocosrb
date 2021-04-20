require 'orocos/test'
require 'orocos/async'

describe Orocos::Async::PortProxy do
    describe "when not connected" do
        it "should be an input and output port at the same time because the exact type is unknown" do
            t1 = Orocos::Async.proxy("process_Test")
            p = t1.port("test")
            assert p.input?
            assert p.output?
        end

        it "should raise Orocos::NotFound if some one is accessing the type name of a port which is not yet known" do
            t1 = Orocos::Async.proxy("simple_source_source")
            p = t1.port("cycle")
            assert_raises Orocos::NotFound do
                p.type_name
            end
        end

        it "should return a sub port for a given subfield" do
            t1 = Orocos::Async.proxy("simple_source_source")
            p = t1.port("cycle")
            sub_port = p.sub_port(:frame)
            assert_kind_of Orocos::Async::SubPortProxy, sub_port
            sub_port = p.sub_port(%I[frame size])
            assert_kind_of Orocos::Async::SubPortProxy, sub_port
        end
    end

    describe "when connected" do
        it "should raise RuntimeError if an operation is performed which is not available for this port type" do
            Orocos.run('simple_sink') do
                t1 = Orocos::Async.proxy("simple_sink_sink")
                p = t1.port("cycle", wait: true)
                assert_raises RuntimeError do
                    p.period = 1
                end
                assert_raises RuntimeError do
                    p.on_data do
                    end
                end
            end
        end

        it "should return the type name of the port if known or connected" do
            t1 = Orocos::Async.proxy("simple_source_source",:retry_period => 0.2,:period => 0.2)
            p = t1.port("cycle2",:type => Integer)
            expected =
                if Fixnum == Integer
                    "Integer"
                else
                    "Fixnum"
                end

            assert_equal expected, p.type_name

            p2 = t1.port("cycle")
            Orocos.run('simple_source') do
                p2.wait
                assert_equal Fixnum.to_s, p.type_name
            end
        end

        it "should raise RuntimeError if the given type name differes from the real one" do
            Orocos.run('simple_sink') do
                t1 = Orocos::Async.proxy("simple_sink_sink")
                assert_raises RuntimeError do
                    p = t1.port("cycle",:type => Float,:wait => true)
                end
            end
        end

    end

    describe 'on_reachable' do
        it 'must be called once when the port is reachable' do
            p = Orocos::Async.proxy("simple_sink_sink").port("cycle")
            counter = 0
            p.on_reachable do
                counter += 1
            end
            Orocos.run('simple_sink') do
                p.wait
                Orocos::Async.steps
            end
            assert_equal 1,counter
        end
    end

end

describe Orocos::Async::SubPortProxy do
    include Orocos::Spec

    describe "when not connected" do
        it "should raise if the type is accessed but not given" do
            t1 = Orocos::Async.proxy("simple_source_source")
            p = t1.port("cycle")
            sub_port = p.sub_port(:value)
            assert_raises Orocos::NotFound do
                sub_port.type
            end
        end
    end

    describe "when connected" do
        it "should return the given sub type" do
            t1 = Orocos::Async.proxy("simple_source_source")
            Orocos.run('simple_source') do
                p = t1.port("cycle_struct",:wait => true)
                sub_port = p.sub_port(:value)
                assert_equal Orocos.registry.get("/int32_t"),sub_port.type
                assert_equal "/int32_t",sub_port.type_name
            end
        end

        it "should raise RuntimeError if the given sub type differs from the real one" do
            t1 = Orocos::Async.proxy("simple_source_source",:period => 0.009)
            Orocos.run('simple_source') do
                p = t1.port("cycle_struct",:type => Orocos.registry.get("std/string"))
                sub_port = p.sub_port(:value)
                assert_raises RuntimeError do
                    sub_port.wait
                end
            end
        end

        it "should call the code block with the sub sample" do
            t1 = Orocos::Async.proxy("simple_source_source",:period => 0.009)
            Orocos.run('simple_source') do
                p = t1.port("cycle_struct",:wait => true)
                sub_port = p.sub_port(:value)
                data = nil
                sub_port.on_data do |sample|
                    data = sample
                end
                t1.configure
                t1.start
                wait_for { data }
                assert_kind_of Fixnum, data
            end
        end
    end
end

describe Orocos::Async::PropertyProxy do
    include Orocos::Spec

    describe "on_reachable" do
        it "must be called once when a prop gets reachable" do
            prop = Orocos::Async.proxy("process_Test", period: 0.09).property("prop1")
            counter = 0
            prop.on_reachable do
                counter +=1
            end
            Orocos.run('process') do
                wait_for { counter > 0 }
            end
            Orocos::Async.steps
            assert_equal 1,counter
        end
    end

    describe "on_unreachable" do
        it "must be called once when a prop is or gets unreachable" do
            prop = Orocos::Async.proxy("process_Test",:period => 0.09).property("prop1")
            counter = 0
            prop.on_unreachable do
                counter += 1
            end
            wait_for { !prop.valid_delegator? }
            assert_equal 1, counter

            Orocos.run("process") do
                prop.wait
                wait_for { prop.valid_delegator? }
                assert prop.valid_delegator?
            end
            wait_for { counter == 2 }
        end
    end
end

describe Orocos::Async::AttributeProxy do
    include Orocos::Spec

    describe "when not connected" do
        it "should raise Orocos::NotFound if someone is accessing the type name of the attribute which is not yet known" do
            t1 = Orocos::Async.proxy("process_Test")
            p = t1.attribute("att1")
            assert_raises Orocos::NotFound do
                p.type_name
            end
        end
        it "should call unreachable" do
            t1 = Orocos::Async.proxy("process_Test")
            counter = 0
            counter2 = 0
            t1.on_unreachable do
                counter += 1
            end
            t1.on_reachable do
                counter2 += 1
            end
            Orocos::Async.steps
            assert_equal 1,counter
            assert_equal 0,counter2
        end
    end

    describe "when connected" do
        it "should return the type name of the attribute if known or connected" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.08,:period => 0.1)
            p = t1.attribute("att2",:type => Orocos.registry.get("int32_t"))
            assert_equal "/int32_t",p.type_name

            p2 = t1.attribute("att3")
            Orocos.run('process') do
                wait_for do
                    p2.reachable?
                end
                assert_equal "/std/string",p2.type_name
            end
        end

        it "should raise RuntimeError if the given type name differes from the real one" do
            Orocos.run('process') do
                t1 = Orocos::Async.proxy("process_Test")
                assert_raises RuntimeError do
                    p = t1.attribute("att1",:type => Float,:wait => true)
                end
            end
        end

        it "should call on_change when the value is changed" do
            Orocos.run('process') do
                t  = Orocos.name_service.get 'process_Test'
                t1 = Orocos::Async.proxy("process_Test")
                p = t1.attribute("att2",:wait => true,:period=>0)

                # 84 is the magical hardcoded initialization value in the
                # process::Task constructor
                listener = flexmock
                listener.should_receive(:data).with(84).once
                listener.should_receive(:data).with(10).once
                p.on_change { |data| listener.data(data) }
                Orocos::Async.steps
                t.attribute('att2').write(10)
                Orocos::Async.steps
            end
        end

        it "should reconnect" do
            t1 = Orocos::Async.proxy("process_Test", retry_period: 0.09)
            p = t1.attribute("att2")
            vals = []
            p.on_change do |data|
                vals << data
            end

            Orocos.run("process") do
                wait_for { p.valid_delegator? }
                wait_for { vals.size == 1 }
            end

            wait_for { !t1.valid_delegator? }
            refute p.valid_delegator?

            Orocos.run("process") do
                wait_for { p.valid_delegator? }
                wait_for { vals.size == 2 }
            end
        end
    end
end

describe Orocos::Async::PropertyProxy do
    include Orocos::Spec

    describe "when not connected" do
        it "should raise Orocos::NotFound if someone is accessing the type name of the property which is not yet known" do
            t1 = Orocos::Async.proxy("process_Test")
            p = t1.property("prop1")
            assert_raises Orocos::NotFound do
                p.type_name
            end
        end
    end

    describe "when connected" do
        it "should return the type name of the property if known or connected" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.08,:period => 0.1)
            p = t1.property("prop2",:type => Orocos.registry.get("int32_t"))
            assert_equal "/int32_t",p.type_name

            p2 = t1.property("prop3")
            Orocos.run('process') do
                wait_for do
                    p2.reachable?
                end
                assert_equal "/std/string",p2.type_name
            end
        end

        it "should raise RuntimeError if the given type name differes from the real one" do
            Orocos.run('process') do
                t1 = Orocos::Async.proxy("process_Test")
                assert_raises RuntimeError do
                    p = t1.property("prop1",:type => Float,:wait => true)
                end
            end
        end

        it "should call on_change when the value is changed" do
            Orocos.run('process') do
                t  = Orocos.name_service.get 'process_Test'
                t1 = Orocos::Async.proxy("process_Test")
                p = t1.property("prop2",:wait => true,:period=>0)

                # 84 is the magical hardcoded initialization value in the
                # process::Task constructor
                listener = flexmock
                listener.should_receive(:data).with(84).once.ordered
                listener.should_receive(:data).with(10).once.ordered
                p.on_change { |data| listener.data(data) }
                Orocos::Async.steps
                t.property('prop2').write(10)
                Orocos::Async.steps
            end
        end

        it "should reconnect" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.09,:period => 0.09)
            p = t1.property("prop2")
            vals = Array.new
            p.on_change do |data|
                vals << data
            end

            Orocos.run('process') do
                wait_for { vals.size >= 1 }
            end
            Orocos::Async.steps

            Orocos.run('process') do
                wait_for { vals.size == 2 }
            end
            assert_equal 2,vals.size
        end
    end
end

describe Orocos::Async::TaskContextProxy do
    include Orocos::Spec

    describe "initialize" do
        it "should raise Orocos::NotFound if remote task is unreachable and :raise is set to true" do
            t1 = Orocos::Async::TaskContextProxy.new("bla0",:raise => true)
            assert_raises(Orocos::NotFound) do
                Orocos::Async.steps
            end
            assert !t1.reachable?
            # clear all errors
            Orocos::Async.event_loop.clear_errors
        end

        it "should not raise NotFound if remote task is unreachable and :raise is set to false" do
            t1 = Orocos::Async::TaskContextProxy.new("bla1",:raise => false)
            Orocos::Async.steps
            assert !t1.reachable?
        end

        it "should raise NotFound if a method is called while task is unreachable" do
            t1 = Orocos::Async::TaskContextProxy.new("bla2")
            Orocos::Async.steps
            assert_raises(Orocos::NotFound) do
                assert !t1.model
            end
        end

        it "should raise Orocos::NotFound if task is not reachable after n seconds" do
            t1 = Orocos::Async::TaskContextProxy.new("bla3")
            assert_raises(Orocos::NotFound) do
                t1.wait(0.1)
            end
        end

        it "shortcut must return TaskContexProxy" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.1,:period => 0.1)
            assert_kind_of Orocos::Async::TaskContextProxy, t1
        end

        it "should return a port proxy" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.1,:period => 0.1)
            p = t1.port("test")
            assert_kind_of Orocos::Async::PortProxy, p
        end

        it "should connect to a remote task when reachable" do
            t1 = Orocos::Async.proxy("process_Test",:retry_period => 0.1,:period => 0.1)

            disconnects = 0
            connects = 0

            t1.on_reachable do
                connects += 1
            end
            t1.on_unreachable do
                disconnects += 1
            end
            assert_equal 0, connects
            assert_equal 0, disconnects
            Orocos::Async.steps
            assert_equal 1, disconnects # on_unreachable will be called because is not yet reachable

            Orocos.run("process") do
                wait_for { t1.reachable? }
                assert_kind_of Orocos::Async::CORBA::TaskContext,
                               t1.instance_variable_get(:@delegator_obj)
                assert_equal 1, disconnects
            end
            refute t1.reachable?
            Orocos::Async.steps # queue reconnect
            assert_equal 1, connects
            assert_equal 2, disconnects

            Orocos.run("process") do
                Orocos::Async.steps # queue reconnect
                assert t1.reachable?
            end
            Orocos::Async.steps # queue reconnect
            refute t1.reachable?
            assert_equal 2, connects
            assert_equal 3, disconnects
        end

        it "should call on_port_reachable if task gets reachable" do
            port = []
            t1 = Orocos::Async.proxy("simple_source_source")
            t1.on_port_reachable do |port_name|
                port << port_name
            end
            Orocos.run('simple_source') do

            end
        end


        it "should block until the task is reachable if wait option is given" do
            Orocos.run('simple_source') do
                t1 = Orocos::Async.proxy("simple_source_source",:wait => true )
                assert t1.reachable?
            end
        end

        it "should connect its port when reachable" do
            t1 = Orocos::Async.proxy("simple_source_source",:retry_period => 0.08,:period => 0.1)
            p = t1.port("cycle")

            data = []
            p.on_data do |d|
                data << d
            end
            #test reconnect logic
            0.upto(2) do
                Orocos.run('simple_source') do
                    Orocos::Async.steps
                    t1.configure{}
                    t1.start{}
                    wait_for(2) { data.size == 3 }
                end
                Orocos::Async.steps
                assert !data.empty?
                data.each_with_index do |d,i|
                    assert i
                end
                data.clear
            end
        end
    end

    describe "#property" do
        it "should allow to override the default period on non-reachable tasks" do
            t1 = Orocos::Async.proxy("simple_source_source")
            att = t1.property("an_attribute", :period => 0.42)
            assert_in_delta 0.42, att.period, 0.00001
        end
        it "should allow to override the default period on reachable tasks" do
            Orocos.run('process') do
                t1 = Orocos::Async.proxy("process_Test")
                att = t1.property("prop2", :wait => true, :period => 0.42)
                assert_in_delta 0.42, att.period, 0.00001
            end
        end
    end

    describe "#attribute" do
        it "should allow to override the default period on reachable tasks" do
            Orocos.run('process') do
                t1 = Orocos::Async.proxy("process_Test")
                att = t1.attribute("att2", :wait => true, :period => 0.42)
                assert_in_delta 0.42, att.period, 0.00001
            end
        end
        it "should allow to override the default period on non-reachable tasks" do
            t1 = Orocos::Async.proxy("process_Test")
            att = t1.attribute("att2", :period => 0.42)
            assert_in_delta 0.42, att.period, 0.00001
        end
    end
end
