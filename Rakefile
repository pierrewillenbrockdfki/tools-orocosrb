require "bundler/gem_tasks"
require "rake/testtask"
require './lib/orocos/rake'


Rake::TestTask.new("test:core") do |t|
    t.libs << "lib"
    t.libs << "."
    test_files = FileList['test/**/test_*.rb']
    test_files.exclude "test/standalone/**/*"
    test_files.exclude "test/async/**/*"
    test_files.exclude "test/ros/**/*"
    t.test_files = test_files
    t.warning = false
end

Rake::TestTask.new("test:ros") do |t|
    t.libs << "lib"
    t.libs << "."
    t.test_files = FileList["test/ros/**/test_*.rb"]
    t.warning = false
end

Rake::TestTask.new("test:async") do |t|
    t.libs << "lib"
    t.libs << "."
    t.test_files = FileList['test/async/**/test_*.rb']
    t.warning = false
end

Rake::TestTask.new("test:standalone") do |t|
    t.libs << "lib"
    t.libs << "."
    t.test_files = FileList['test/standalone/**/test_*.rb']
    t.warning = false
end

task "test" => ["test:core", "test:async", "test:standalone"]
task "test" => "test:ros" unless Orocos::Rake::USE_ROS

def build_orogen(name, options = Hash.new)
    parsed_options = Hash.new
    parsed_options[:keep_wc] =
        if ['1', 'true'].include?(options[:keep_wc]) then true
        else false
        end
    parsed_options[:transports] = (options[:transports] || "corba typelib mqueue").split(" ")
    if parsed_options[:transports].empty?
        parsed_options[:transports] = nil
    elsif parsed_options[:transports] == 'none'
        parsed_options[:transports] = []
    end

    parsed_options[:make_options] = Shellwords.split(options[:make_options] || "").
        map { |opt| opt.gsub(';', ',') }
    work_dir = File.expand_path(File.join('test', 'working_copy'))
    data_dir = File.expand_path(File.join('test', 'data'))

    Orocos::Rake.generate_and_build \
        File.join(data_dir, name, "#{name}.orogen"),
        work_dir, parsed_options
end

task 'default' do
    Rake::Task['clean'].invoke
    Rake::Task['compile'].invoke
end

# Leave in top level namespace to allow rake-compiler to build native gem: 'rake native gem'
require 'rake/extensiontask'
desc "builds Orocos.rb C extension"
Rake::ExtensionTask.new('rorocos') do |ext|
    # Same info as in ext/rocoros/extconf.rb where cmake
    # is used to generate the Makefile
    ext.name = "rorocos"
    ext.ext_dir = "ext/rorocos"
    ext.lib_dir = "lib/orocos"
    ext.source_pattern = "*.{c,cpp,cc}"

    if not Dir.exist?(ext.tmp_dir)
        FileUtils.mkdir_p ext.tmp_dir
    end
end

namespace :setup do
    desc "builds the oroGen modules that are needed by the tests"
    task :orogen_all, [:keep_wc,:transports,:make_options] do |_, args|
        build_orogen 'process', args
        build_orogen 'simple_sink', args
        build_orogen 'simple_source', args
        build_orogen 'echo', args
        build_orogen 'operations', args
        build_orogen 'configurations', args
        build_orogen 'states', args
        build_orogen 'uncaught', args
        build_orogen 'system', args
    end

    desc "builds the test 'process' module"
    task :orogen_process, [:keep_wc,:transports,:update] do |_, args| build_orogen 'process', args end
    desc "builds the test 'simple_sink' module"
    task :orogen_sink, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'simple_sink', args end
    desc "builds the test 'simple_source' module"
    task :orogen_source, [:keep_wc,:transports,:update]  do |_, args| build_orogen 'simple_source', args end
    desc "builds the test 'echo' module"
    task :orogen_echo, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'echo', args end
    desc "builds the test 'states' module"
    task :orogen_states, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'states', args end
    desc "builds the test 'uncaught' module"
    task :orogen_uncaught, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'uncaught', args end
    desc "builds the test 'system' module"
    task :orogen_system, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'system', args end
    desc "builds the test 'operations' module"
    task :orogen_operations, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'operations', args end
    desc "builds the test 'configurations' module"
    task :orogen_configurations, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'configurations', args end
    desc "builds the test 'ros_test' module"
    task :orogen_ros_test, [:keep_wc,:transports,:update]    do |_, args| build_orogen 'ros_test', args end

    task :test do |t, args|
        Rake::Task['setup:orogen_all'].invoke('1', '', '1')
    end
end

require 'yard/rake/yardoc_task'
YARD::Rake::YardocTask.new

task :doc => :yard
task :docs => :yard
task :redoc => :yard
task :redocs => :yard

