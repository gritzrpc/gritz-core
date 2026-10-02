# frozen_string_literal: true

require "io/wait"

module Gritz
  module Worker
    # Owns transport resources and heartbeats in one serving process.
    # @api private
    class Runner
      def initialize(index:, config:, logger:, status_io: nil)
        @index = index
        @config = config
        @logger = logger
        @status = Supervisor::StatusChannel.new(status_io) if status_io
      end

      def run
        @exit_status = 0
        begin
          @signals = Supervisor::SignalQueue.new(signals: %w[TERM INT QUIT HUP])
          report("booting")
          require "gritz/native"
          @boot_started = true
          @config.preload! unless @config.preload_app?
          @config.run_hooks(:on_worker_boot, @index)
          router = Router.new(controllers: @config.controllers, strict: @config.strict_routes, logger: @logger)
          dispatcher = Dispatcher.new(router:, middleware: @config.middleware, logger: @logger)
          @adapter = Transport::Native.new(config: @config, dispatcher:, logger: @logger)
          @port = @adapter.bind(@config.bind)
          @adapter.start
          @logger.info("Gritz #{Core::VERSION} listening on #{@config.bind.sub(/:\d+\z/, ":#{@port}")}")
          report("ready")
          serve
        rescue StandardError, LoadError, SyntaxError, SystemExit => e
          fail_worker(e)
        ensure
          finish
        end
        @exit_status
      end

      private

      def serve
        next_status = monotonic + @config.status_interval
        loop do
          raise ConfigurationError, "gRPC server stopped unexpectedly" unless @adapter.running?
          raise ConfigurationError, "worker status pipe closed" if @status&.closed?

          @signals.drain.each do |name|
            case name
            when "HUP" then @logger.reopen
            when "QUIT"
              report("draining")
              @adapter.kill
              @transport_stopped = true
              return 0
            when "TERM", "INT"
              report("draining")
              @adapter.stop(deadline: Time.now + @config.shutdown_timeout)
              @transport_stopped = true
              return 0
            end
          end
          now = monotonic
          if now >= next_status
            report("ready")
            next_status = now + @config.status_interval
          end
          @signals.io.wait_readable([next_status - monotonic, 0].max)
        end
      end

      def report(state, include_stats: true, **extra)
        return unless @status

        stats = include_stats && @adapter ? @adapter.stats : {}
        row = { inflight: 0, capacity: @config.threads, requests_total: 0, oldest_inflight_age: 0 }.merge(stats)
        row.merge!(pid: Process.pid, index: @index, state:, ts: monotonic, port: @port,
                   busy_threads: stats.fetch(:busy_threads, stats.fetch(:busy, 0)))
        @status.write(row.merge(extra))
      end

      def fail_worker(error)
        @exit_status = 1
        @logger.error(error.full_message)
        report("failed", include_stats: false, error: error.message[0, 512])
      end

      def finish
        cleanup { @adapter&.kill unless @transport_stopped }
        cleanup { @config.run_hooks(:on_worker_shutdown, @index) if @boot_started }
        report("stopped", include_stats: false, exit_status: @exit_status)
      ensure
        begin
          @signals&.close
        ensure
          @status&.close
        end
      end

      def cleanup
        yield
      rescue StandardError, LoadError, SyntaxError, SystemExit => e
        fail_worker(e)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
