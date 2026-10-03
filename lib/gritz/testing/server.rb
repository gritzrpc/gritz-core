# frozen_string_literal: true

require "logger"

module Gritz
  module Testing
    # Starts a single-process server for integration tests.
    # @api public
    class Server
      attr_reader :port, :address, :transport

      def self.start(config = nil, controllers: nil, middleware: nil, logger: Logger.new(File::NULL))
        config ||= Configuration.new.tap do |settings|
          settings.workers = 0
          settings.bind = "127.0.0.1:0"
        end
        config.controllers = controllers if controllers
        config.middleware = middleware if middleware
        server = new(config, logger:).start
        return server unless block_given?

        begin
          yield server
        ensure
          server.stop
        end
      end

      def initialize(config, logger:)
        @config = config
        @logger = logger
        config.validate_single_process!
      end

      def start
        raise ArgumentError, "Testing::Server is already started or stopped" if @started || @stopped

        @started = true
        begin
          @config.preload! if @config.preload_app?
          router = Router.new(controllers: @config.controllers, strict: @config.strict_routes, logger: @logger)
          @lifecycle_started = true
          @config.run_hooks(:on_worker_boot, 0)
          @recorder = @config.metrics_recorder_factory&.call(worker: 0)
          dispatcher = Dispatcher.new(router:, middleware: @config.middleware, logger: @logger, metrics: @recorder)
          @transport = Transport.const_get(@config.transport.to_s.capitalize).new(config: @config, dispatcher:, logger: @logger)
          @port = transport.bind
          @address = @config.bind.sub(/:\d+\z/, ":#{port}")
          transport.start
          unless @config.health_checks.empty?
            @health_stop = Queue.new
            @health_thread = Thread.new do
              transport.refresh_health until @health_stop.pop(timeout: @config.status_interval)
            end
          end
          self
        rescue StandardError
          stop
          raise
        end
      end

      def stop
        return if @stopped

        @stopped = true
        deadline = monotonic + @config.shutdown_timeout
        begin
          @health_stop&.push(true)
          if @health_thread && !@health_thread.join([deadline - monotonic, 0].max)
            @health_thread.kill.join
          end
          transport&.stop(deadline: Time.now + [deadline - monotonic, 0].max)
        ensure
          begin
            @config.run_hooks(:on_worker_shutdown, 0) if @lifecycle_started
          ensure
            begin
              @recorder&.observe_rejected(transport.stats.fetch(:rejected_total, 0)) if transport
              @recorder&.observe_worker({ pid: Process.pid, index: 0, state: "stopped" })
            ensure
              @recorder&.close(timeout: [deadline - monotonic, 0].max)
            end
          end
        end
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
