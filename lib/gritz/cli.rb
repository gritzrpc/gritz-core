# frozen_string_literal: true

require "optparse"
require "logger"

module Gritz
  # Command line entry point for the single-process server and route listing.
  # @api public
  class CLI
    def initialize(stdout: $stdout, stderr: $stderr, env: ENV)
      @stdout = stdout
      @stderr = stderr
      @env = env
    end

    def run(argv)
      args = argv.dup
      path = nil
      overrides = {}
      parser = OptionParser.new do |options|
        options.banner = "Usage: gritz [start|routes] [-C config/gritz.rb] [options]"
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
      raise ConfigurationError, "Unknown command #{command}" unless %w[start routes].include?(command)
      raise ConfigurationError, "Unexpected argument #{args.first}" unless args.empty?

      path ||= "config/gritz.rb" if File.file?("config/gritz.rb")
      config = Configuration.load(path: path, env: @env, overrides: overrides)
      config.validate_single_process! if command == "start"
      config.preload! if config.preload_app?
      logger = Logger.new(@stdout)
      logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
      router = Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
      if command == "routes"
        router.routes.each_value do |route|
          @stdout.puts "#{route.full_name} #{route.kind} #{route.controller}##{route.action}"
        end
      else
        start(config, router, logger)
      end
      0
    rescue ConfigurationError, OptionParser::ParseError, ArgumentError, Errno::ENOENT, SyntaxError, LoadError => e
      @stderr.puts "gritz: #{e.message}"
      1
    end

    private

    def start(config, router, logger)
      @stdout.sync = true if @stdout.respond_to?(:sync=)
      # Load the adapter only when starting; route inspection stays transport-independent.
      require "gritz/native"
      dispatcher = Dispatcher.new(router: router, middleware: config.middleware, logger: logger)
      adapter = Transport::Native.new(config: config, dispatcher: dispatcher, logger: logger)
      signals = []
      previous = %w[TERM INT QUIT].to_h { |name| [name, Signal.trap(name) { signals << name }] }
      config.run_hooks(:on_worker_boot, 0)
      port = adapter.bind(config.bind)
      adapter.start
      logger.info("Gritz #{Core::VERSION} listening on #{config.bind.sub(/:\d+\z/, ":#{port}")}")
      while signals.empty?
        sleep 0.05
        raise ConfigurationError, "gRPC server stopped unexpectedly" unless adapter.running?
      end
      signals.shift == "QUIT" ? adapter.kill : adapter.stop(deadline: Time.now + config.shutdown_timeout)
    ensure
      previous&.each { |name, handler| Signal.trap(name, handler) }
      adapter&.kill if adapter&.running?
      config.run_hooks(:on_worker_shutdown, 0)
    end
  end
end
