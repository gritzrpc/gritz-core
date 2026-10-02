# frozen_string_literal: true

require "optparse"
require "logger"

module Gritz
  # Starts a server, lists routes, or checks configuration and fork safety.
  # @api public
  class CLI
    def initialize(stdout: $stdout, stderr: $stderr, env: ENV, status_io: nil)
      @stdout = stdout
      @stderr = stderr
      @env = env
      @status_io = status_io
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

      path ||= "config/gritz.rb" if File.file?("config/gritz.rb")
      guard = ForkGuard.activate(mode: :record) if command != "routes"
      require "gritz/native" if command != "routes"
      config = Configuration.load(path: path, env: @env, overrides: overrides)
      logger = Logger.new(@stdout)
      logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
      if command == "check"
        config.preload! if config.preload_app?
        guard.violations.each { |violation| @stderr.puts(violation.message) }
        return 1 unless guard.violations.empty?

        config.validate_runtime!
        Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
        @stdout.puts "Configuration and fork safety checks passed"
      elsif command == "start"
        config.validate_runtime!
        if config.workers.positive? && config.fork_mode == :clean
          raise guard.violations.first if config.fork_guard == :raise && !guard.violations.empty?

          guard.violations.each { |violation| logger.warn(violation.message) } if config.fork_guard == :warn
        end
        @stdout.sync = true if @stdout.respond_to?(:sync=)
        return Supervisor::Master.new(config, logger: logger, status_io: @status_io).run if config.workers.positive?

        ForkGuard.deactivate
        config.preload! if config.preload_app?
        return Worker::Runner.new(index: 0, config: config, logger: logger).run
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
    end
  end
end
