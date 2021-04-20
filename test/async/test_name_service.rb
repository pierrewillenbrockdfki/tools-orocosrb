require 'orocos/test'
require 'orocos/async'

describe Orocos::Async::NameService do
    before do
        Orocos::Async.clear
    end

    it "should have a global default instance" do
        Orocos::Async.name_service.must_be_instance_of Orocos::Async::NameService
    end

    it "should raise NotFound if remote task is not reachable" do
        ns = Orocos::Async::NameService.new
        assert_raises Orocos::NotFound do
            ns.get "bla"
        end
    end

    it "should be reachable" do
        assert Orocos::Async.name_service.reachable?
    end

    it "should return a TaskContextProxy" do
        Orocos.run('process') do
            ns = Orocos::Async::NameService.new
            ns << Orocos::CORBA::NameService.new

            t = ns.get "process_Test"
            assert_kind_of Orocos::Async::CORBA::TaskContext, t

            t2 = nil
            ns.get("process_Test") { |task| t2 = task }
            wait_for { t2 }
            assert_kind_of Orocos::Async::CORBA::TaskContext, t2
        end
    end

    it "should report that new task are added and removed" do
        ns = Orocos::Async::NameService.new(:period => 0)
        ns << Orocos::CORBA::NameService.new
        names_added = []
        names_removed = []
        ns.on_task_added do |n|
            names_added << n
        end
        ns.on_task_removed do |n|
            names_removed << n
        end
        Orocos::Async.steps
        Orocos.run('process') do
            Orocos::Async.steps
            assert_equal 1,names_added.size
            assert_equal 0,names_removed.size
            assert_equal "/process_Test",names_added.first
        end
        Orocos::Async.steps
        assert_equal 1,names_added.size
        assert_equal 1,names_removed.size
        assert_equal "/process_Test",names_removed.first
    end
end
