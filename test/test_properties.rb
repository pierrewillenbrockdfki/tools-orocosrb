$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
require 'minitest/spec'
require 'orocos'
require 'orocos/test'

MiniTest::Unit.autorun

TEST_DIR = File.expand_path(File.dirname(__FILE__))
DATA_DIR = File.join(TEST_DIR, 'data')
WORK_DIR = File.join(TEST_DIR, 'working_copy')

describe "reading and writing properties on TaskContext" do
    include Orocos::Spec

    it "should be able to read string property values" do
        Orocos::Process.spawn('process') do |process|
            prop = process.task('Test').property('prop3')
            assert_equal('42', prop.read)
        end
    end

    it "should be able to read property values from a simple type" do
        Orocos::Process.spawn('process') do |process|
            prop = process.task('Test').property('prop2')
            assert_equal(84, prop.read)
        end
    end

    it "should be able to read property values from a complex type" do
        Orocos::Process.spawn('process') do |process|
            prop1 = process.task('Test').property('prop1')

            value = prop1.read
            assert_equal(21, value.a)
            assert_equal(42, value.b)
        end
    end

    it "should be able to write a property of a simple type" do
        Orocos::Process.spawn('process') do |process|
            prop = process.task('Test').property('prop2')
            prop.write(80)
            assert_equal(80, prop.read)
        end
    end

    it "should be able to write string property values" do
        Orocos::Process.spawn('process') do |process|
            prop = process.task('Test').property('prop3')
            prop.write('84')
            assert_equal('84', prop.read)
        end
    end

    it "should be able to write a property of a complex type" do
        Orocos::Process.spawn('process') do |process|
            prop = Orocos::TaskContext.get('process_Test').property('prop1')

            value = prop.type.new
            value.a = 22
            value.b = 43
            prop.write(value)

            value = prop.read
            assert_equal(22, value.a)
            assert_equal(43, value.b)
        end
    end
end

