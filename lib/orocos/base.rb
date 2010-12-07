require 'orogen'
require 'typelib'
require 'utilrb/module/attr_predicate'
require 'orogen'

module Orocos
    class InternalError < Exception; end

    def self.register_pkgconfig_path(path)
    	base_path = caller(1).first.gsub(/:\d+:.*/, '')
	ENV['PKG_CONFIG_PATH'] = "#{File.expand_path(path, File.dirname(base_path))}:#{ENV['PKG_CONFIG_PATH']}"
    end

    # Exception raised when the user tries an operation that requires the
    # component to be generated by oroGen, while the component is not
    class NotOrogenComponent < Exception; end

    class << self
        # The Typelib::Registry instance that is the union of all the loaded
        # component's type registries
        attr_reader :registry

        # The master oroGen project through  which all the other oroGen projects
        # are imported
        attr_reader :master_project

        # The set of orogen projects that are available, as a mapping from a
        # name into the project's orogen description file
        attr_reader :available_projects

        # The set of available deployments, as a mapping from the deployment
        # name into the Utilrb::PkgConfig object that represents it
        attr_reader :available_deployments

        # The set of available task libraries, as a mapping from the task
        # library name into the Utilrb::PkgConfig object that represent it
        attr_reader :available_task_libraries

        # The set of available task models, as a mapping from the model name
        # into the task library name that defines it
        attr_reader :available_task_models
    end

    # True if there is a typekit named +name+ on the file system
    def self.has_typekit?(name)
        pkg, _ = available_projects[name]
        pkg && pkg.type_registry
    end

    def self.typelib_type_for(t)
        if t.respond_to?(:name)
            return t if t < Typelib::NumericType
            t = t.name
        end
        registry.get(do_typelib_type_for(t))
    end

    def self.orocos_target
        if ENV['OROCOS_TARGET']
            ENV['OROCOS_TARGET']
        else
            'gnulinux'
        end
    end

    # Helper method for initialize
    def self.add_project_from(pkg) # :nodoc:
        project = pkg.project_name
        if project.empty?
            Orocos.warn "#{pkg.name}.pc does not have a project_name field"
        end
        if description = available_projects[project]
            return description
        end

        if pkg.deffile.empty?
            Orocos.warn "#{pkg.name}.pc does not have a deffile field"
        else
            available_projects[pkg.project_name] = [pkg, pkg.deffile]
        end
    end

    def self.load
        @master_project = Orocos::Generation::Component.new
        @registry = master_project.registry
        @available_projects ||= Hash.new

        # Finally, update the set of available projects
        Utilrb::PkgConfig.each_package(/^orogen-project-/) do |pkg_name|
            if !available_projects.has_key?(pkg_name)
                pkg = Utilrb::PkgConfig.new(pkg_name)
                add_project_from(pkg)
            end
        end

        # Load the name of all available task libraries
        if !available_task_libraries
            @available_task_libraries = Hash.new
            Utilrb::PkgConfig.each_package(/-tasks-#{Orocos.orocos_target}$/) do |pkg_name|
                pkg = Utilrb::PkgConfig.new(pkg_name)
                tasklib_name = pkg_name.gsub(/-tasks-#{Orocos.orocos_target}$/, '')
                available_task_libraries[tasklib_name] = pkg

                add_project_from(pkg)
            end
        end

        if !available_deployments
            @available_deployments = Hash.new
            Utilrb::PkgConfig.each_package(/^orogen-\w+$/) do |pkg_name|
                pkg = Utilrb::PkgConfig.new(pkg_name)
                deployment_name = pkg_name.gsub(/^orogen-/, '')
                available_deployments[deployment_name] = pkg

                add_project_from(pkg)
            end
        end

        # Create a class_name => tasklib mapping for all task models available
        # on this sytem
        if !available_task_models
            @available_task_models = Hash.new
            available_task_libraries.each do |tasklib_name, tasklib_pkg|
                tasklib_pkg.task_models.split(",").
                    each { |class_name| available_task_models[class_name] = tasklib_name }
            end
        end
    end

    class << self
        attr_predicate :disable_sigchld_handler, true
    end

    # Initialize the Orocos communication layer and load all the oroGen models
    # that are available.
    #
    # This method will verify that the pkg-config environment is sane, as it is
    # demanded by the oroGen deployments. If it is not the case, it will raise
    # a RuntimeError exception whose message will describe the particular
    # problem. See the "Error messages" package in the user's guide for more
    # information on how to fix those.
    def self.initialize
        if !registry
            self.load
        end

        # Set up the RTT itself
        do_initialize

        # oroGen components use pkg-config --list-all to find where all typekit
        # files are.  Unfortunately, Debian and debian-based system sometime
        # have pkg-config --list-all broken because of missing dependencies
        #
        # Detect it and present an error message to the user if it is the case
        if !system("pkg-config --list-all > /dev/null 2>&1")
            raise RuntimeError, "pkg-config --list-all returns an error. Run it in a console and install packages that are reported."
        end

        # Install the SIGCHLD handler if it has not been disabled
        if !disable_sigchld_handler?
            trap('SIGCHLD') do
                begin
                    while dead = ::Process.wait(-1, ::Process::WNOHANG)
                        if mod = Orocos::Process.from_pid(dead)
                            mod.dead!($?)
                        end
                    end
                rescue Errno::ECHILD
                end
            end
        end

        Orocos::CORBA.init
    end

    # This method assumes that #add_logger has been called at the end of each
    # static_deployment block.
    def self.log_all_ports(options = Hash.new)
        exclude_ports = options[:exclude_ports]
        exclude_types = options[:exclude_types]

        each_process do |process|
            process.log_all_ports(options)
        end
    end

    # call-seq:
    #   Orocos.each_task do |task| ...
    #   end
    #
    # Enumerates the tasks that are currently available on this sytem (i.e.
    # registered on the name server). They are provided as TaskContext
    # instances.
    def self.each_task
        task_names.each do |name|
            task = begin TaskContext.get(name)
                   rescue Orocos::NotFound
                       CORBA.unregister(name)
                   end
            yield(task) if task
        end
    end
end

