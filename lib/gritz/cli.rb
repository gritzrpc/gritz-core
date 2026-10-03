# frozen_string_literal: true

require "optparse"
require "logger"
require "rbconfig"
require "socket"

module Gritz
  # Starts a server, lists routes, or checks configuration and fork safety.
  # @api public
  class CLI
    CHILD_BOOTSTRAP = <<~RUBY
      require "socket"
      fd = ENV.delete("GRITZ_INTERNAL_OWNER_FD")
      exit Gritz::CLI.new(owner_io: UNIXSocket.for_fd(Integer(fd))).run(ARGV)
    RUBY

    def self.child_command(argv)
      library = defined?(Transport::Async) ? "gritz/async" : "gritz/core"
      [RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-r#{library}", "-e", CHILD_BOOTSTRAP, "--", *argv]
    end

    def initialize(stdout: $stdout, stderr: $stderr, env: ENV, status_io: nil, owner_io: nil, launch: false, launch_command: nil)
      @stdout = stdout
      @stderr = stderr
      @env = env
      @status_io = status_io
      @owner_channel = Supervisor::StatusChannel.new(owner_io) if owner_io
      @launch = launch
      @launch_command = launch_command
    end

    def run(argv)
      args = argv.dup
      path = nil
      overrides = {}
      parser = OptionParser.new do |options|
        options.banner = "Usage: gritz [start|routes|check] [-C config/gritz.rb] [options]"
        options.on("-C", "--config PATH", "Configuration file") { |value| path = value }
        options.on("--workers N", Integer) { |value| overrides[:workers] = value }
        options.on("--threads N", Integer) { |value| overrides[:threads] = value }
        options.on("--bind ADDRESS") { |value| overrides[:bind] = value }
        options.on("--strict-routes") { overrides[:strict_routes] = true }
        options.on("-v", "--version") {
          @stdout.puts(Core::VERSION)
          return 0
        }
        options.on("-h", "--help") {
          @stdout.puts(options)
          return 0
        }
      end
      parser.parse!(args)
      command = args.shift || "start"
      raise ConfigurationError, "Unknown command #{command}" unless %w[start routes check].include?(command)
      raise ConfigurationError, "Unexpected argument #{args.first}" unless args.empty?

      logger = Logger.new(@stdout)
      logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
      if command == "start" && @launch && !@owner_channel
        return Supervisor::Launcher.new(command: @launch_command || self.class.child_command(argv), env: @env,
                                        stdout: @stdout, stderr: @stderr, logger: logger, status_io: @status_io).run
      end

      path ||= "config/gritz.rb" if File.file?("config/gritz.rb")
      guard = ForkGuard.activate(mode: :record) if command != "routes"
      if command != "routes" && Gem.loaded_specs.key?("gritz-native") && !defined?(Transport::Async)
        require "gritz/native"
      end
      config = Configuration.load(path: path, env: @env, overrides: overrides)
      if command == "check"
        config.preload! if config.preload_app?
        guard.violations.each { |violation| @stderr.puts(violation.message) }
        return 1 unless guard.violations.empty?

        config.validate_runtime!
        require "gritz/#{config.transport}"
        Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
        @stdout.puts "Configuration and fork safety checks passed"
      elsif command == "start"
        config.validate_runtime!
        require "gritz/#{config.transport}"
        if config.workers.positive? && config.fork_mode == :clean
          raise guard.violations.first if config.fork_guard == :raise && !guard.violations.empty?

          guard.violations.each { |violation| logger.warn(violation.message) } if config.fork_guard == :warn
        end
        @stdout.sync = true if @stdout.respond_to?(:sync=)
        @owner_channel&.write(type: "configured", pid: Process.pid, workers: config.workers, bind: config.bind,
                              admin_bind: config.admin_bind, min_ready_workers: config.min_ready_workers, pid_file: config.pid_file,
                              reexec_timeout: config.reexec_timeout, drain_delay: config.drain_delay, shutdown_timeout: config.shutdown_timeout,
                              listener_strategy: config.listener_strategy.to_s)
        if @owner_channel && config.listener_strategy == :inherited_fd
          until @owner_channel.flush
            raise ConfigurationError, "listener owner closed its control channel" if @owner_channel.closed?

            @owner_channel.io.wait_writable(0.01)
          end
          begin
            listener = @owner_channel.io.recv_io(Socket)
          rescue IOError, SocketError => e
            raise ConfigurationError, "listener owner failed to pass its socket: #{e.message}"
          end
        end
        if config.workers.positive?
          return Supervisor::Master.new(config, logger: logger, status_io: @status_io, owner_channel: @owner_channel, listener:).run
        end

        ForkGuard.deactivate
        config.preload! if config.preload_app?
        return Worker::Runner.new(index: 0, config: config, logger: logger, owner_channel: @owner_channel, listener:).run
      else
        config.preload! if config.preload_app?
        router = Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
      end
      if command == "routes"
        router.routes.each_value do |route|
          @stdout.puts "#{route.full_name} #{route.kind} #{route.controller}##{route.action}"
        end
      end
      0
    rescue ConfigurationError, ForkGuard::Violation, ArgumentError, Errno::ENOENT, SyntaxError, LoadError, RuntimeError => e
      @stderr.puts "gritz: #{e.message}"
      1
    ensure
      ForkGuard.deactivate if guard
      @owner_channel&.close
      listener&.close unless listener&.closed?
    end
  end
end
