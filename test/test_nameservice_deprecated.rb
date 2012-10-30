$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'orocos'
require 'minitest/spec'

MiniTest::Unit.autorun

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

module Orocos::Dummy
    class NameService
    end
end

avahi_options = { :searchdomains => [ "_orocosrbtest._tcp" ] }

describe "Nameservice" do
    include Orocos::Spec

    def setup
        Nameservice::reset
    end

    def teardown
        # Reenable CORBA
        Nameservice.reset
        Nameservice.enable('CORBA')
    end

    it "throws on enabling unknown type" do
        assert_raises(NameError) { Nameservice::Provider::get_instance_of("foo", {}) }
    end

    it "throws on resolve without providers" do
        assert_raises(Orocos::NotFound) { Nameservice::resolve("foo") }
    end

    it "throws if resolve fails for AVAHI" do
        Nameservice::enable(:AVAHI, avahi_options)     
        assert_raises(Orocos::NotFound) { Nameservice::resolve("foo") }
    end

    it "retrieves nameservice instance when available" do
        assert(!Nameservice::get(:AVAHI))
        Nameservice::enable(:AVAHI, avahi_options)     
        assert(Nameservice::get(:AVAHI))
    end

    it "allows checking if enabled" do
        assert(!Nameservice.enabled?(:AVAHI))
        Nameservice::enable(:AVAHI, avahi_options)
        assert(Nameservice::enabled?(:AVAHI))
    end

    it "check on required option in AVAHI" do
        assert_raises(ArgumentError) { Nameservice::enable(:AVAHI) }
    end
end
