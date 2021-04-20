require "orocos/test"
require "orocos/async"

describe Orocos::Async::CORBA::Property do
    before do
        Orocos::Async.clear
        @ns = Orocos::Async::NameService.new
        @ns << Orocos::CORBA::NameService.new

        start "process"
        @task = @ns.get("process_Test")
    end

    describe "When connect to a remote task" do
        it "returns a property synchronously" do
            p = @task.property("prop1")
            assert_kind_of Orocos::Async::CORBA::Property, p
        end
        it "returns a property asynchronously" do
            p = nil
            @task.property("prop1") { |prop| p = prop }
            wait_for { p }
            assert_kind_of Orocos::Async::CORBA::Property, p
        end
        it "calls on_change with the property values" do
            p = @task.property("prop2")
            p.period = 0.01

            vals = []
            p.on_change do |data|
                vals << data
            end
            wait_for_equality [84], vals
            p.write 33
            wait_for_equality [84, 33], vals
        end
    end
end

describe Orocos::Async::CORBA::Attribute do
    include Orocos::Spec

    before do
        Orocos::Async.clear
        @ns = Orocos::Async::NameService.new
        @ns << Orocos::CORBA::NameService.new

        start "process"
        @task = @ns.get("process_Test")
    end

    describe "When connect to a remote task" do
        it "returns an attribute object synchronously" do
            a = @task.attribute("att2")
            assert_kind_of Orocos::Async::CORBA::Attribute, a
        end
        it "returns an attribute object asynchronously" do
            a = nil
            @task.attribute("att2") { |prop| a = prop }
            wait_for { a }
            assert_kind_of Orocos::Async::CORBA::Attribute, a
        end
        it "calls on_change with the attribute values" do
            a = @task.attribute("att2")
            a.period = 0.01
            vals = []
            a.on_change do |data|
                vals << data
            end
            wait_for_equality [84], vals
            a.write 33
            wait_for_equality [84, 33], vals
        end
    end
end
