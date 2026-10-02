# frozen_string_literal: true

require "io/wait"

module Gritz
  module Worker
    # Owns transport resources and heartbeats in one serving process.
    # @api private
    class Runner
      def initialize(index:, config:, logger:, status_io: nil, owner_channel: nil)
        @index = index
        @config = config
        @logger = logger
        @owner_channel = owner_channel
        @status = owner_channel || (Supervisor::StatusChannel.new(status_io) if status_io)
        @recorder = Metrics::Recorder.new
        @metrics = Metrics::Aggregator.new
        @metric_seq = 0
        @born_at = monotonic
      end

      def run
        @exit_status = 0
        begin
          @signals = Supervisor::SignalQueue.new(signals: %w[TERM INT QUIT HUP USR1 USR2])
          report("booting")
          require "gritz/native"
          @boot_started = true
          @config.preload! unless @config.preload_app?
          @config.run_hooks(:on_worker_boot, @index)
          @recorder = @config.metrics_recorder_factory.call(worker: @index) if @config.metrics_recorder_factory
          router = Router.new(controllers: @config.controllers, strict: @config.strict_routes, logger: @logger)
          dispatcher = Dispatcher.new(router:, middleware: @config.middleware, logger: @logger, metrics: @recorder,
                                      worker: @index, log_format: @config.log_format, log_redact: @config.log_redact)
          @adapter = Transport::Native.new(config: @config, dispatcher:, logger: @logger)
          @port = @adapter.bind(@config.bind)
          @adapter.start
          unless @status
            @admin = Supervisor::AdminServer.new(bind: @config.admin_bind, status: -> { snapshot }, ready: -> { ready? },
                                                 metrics: -> { @metrics.render(workers: [@last_status].compact) }, logger: @logger)
          end
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
            when "USR1"
              if @config.workers.zero?
                @logger.warn("USR1 requires workers > 0; use USR2 to reload a single-process server")
              else
                drain
              end
            when "USR2"
              if @owner_channel
                @pending_reexec = true
              else
                @logger.warn("USR2 requires the gritz launcher")
              end
            when "QUIT"
              drain
              @adapter.kill
              @transport_stopped = true
              return 0
            when "TERM", "INT"
              drain
              # Supervised children have already waited in the master's drain phase.
              @drain_until ||= monotonic + (@config.workers.zero? ? @config.drain_delay : 0)
            end
          end
          now = monotonic
          if @drain_until && now >= @drain_until
            @stop_deadline = now + @config.shutdown_timeout
            @adapter.stop(deadline: Time.now + @config.shutdown_timeout)
            @transport_stopped = true
            return 0
          end
          @status&.flush
          if @pending_reexec && @owner_channel.write(type: "reexec", pid: Process.pid)
            @pending_reexec = false
          end
          publish_metrics
          @admin&.poll
          if now >= next_status
            report(@draining ? "draining" : "ready")
            next_status = now + @config.status_interval
          end
          next_event = [next_status, @drain_until].compact.min
          IO.select([@signals.io, *@admin&.ios.to_a], nil, nil, (next_event - monotonic).clamp(0, 0.05))
        end
      end

      def report(state, include_stats: true, **extra)
        stats = include_stats && @adapter ? @adapter.stats : {}
        @recorder.observe_rejected(stats.fetch(:rejected_total, 0)) if include_stats && @adapter
        evaluate_health if state == "ready"
        row = { inflight: 0, capacity: @config.threads, requests_total: 0, oldest_inflight_age: 0 }.merge(stats)
        row.merge!(pid: Process.pid, index: @index, state:, ts: monotonic, port: @port,
                   busy_threads: stats.fetch(:busy_threads, stats.fetch(:busy, 0)), healthy: state == "ready" && @healthy,
                   checks: @checks || {}, worker_started_at: @born_at)
        @last_status = row.merge(extra)
        @recorder.observe_worker(@last_status)
        @status&.write(@owner_channel ? snapshot : @last_status)
      end

      def snapshot
        { type: "status", pid: Process.pid, state: @draining ? "draining" : "running", desired: 1, workers: [@last_status].compact }
      end

      def ready? = !@draining && @last_status && @last_status[:state] == "ready" && @last_status[:healthy]

      def evaluate_health
        @checks = @config.health_checks.to_h do |name, callback|
          [name, callback.call ? true : false]
        rescue StandardError => e
          @logger.warn("Health check #{name}: #{e.message}")
          [name, false]
        end
        @healthy = @adapter.update_health(ready: true, checks: @checks)
      end

      def drain
        return if @draining

        @draining = true
        @adapter.drain!
        report("draining")
      end

      def publish_metrics
        @pending_delta ||= @recorder.take_delta
        return true unless @pending_delta

        packet = { type: "metrics", pid: Process.pid, worker_pid: Process.pid, worker_started_at: @born_at,
                   seq: @metric_seq + 1, delta: @pending_delta }
        accepted = @status ? @status.write(packet) : @metrics.apply(self, packet)
        if accepted
          @metric_seq += 1
          @pending_delta = nil
        end
        accepted
      end

      def fail_worker(error)
        @exit_status = 1
        @logger.error(error.full_message)
        report("failed", include_stats: false, error: error.message[0, 512])
      end

      def finish
        cleanup { @adapter&.kill unless @transport_stopped }
        cleanup { @config.run_hooks(:on_worker_shutdown, @index) if @boot_started }
        cleanup { @recorder.observe_rejected(@adapter.stats.fetch(:rejected_total, 0)) if @adapter }
        deadline = @stop_deadline || (monotonic + @config.shutdown_timeout)
        loop do
          @status&.flush
          accepted = publish_metrics
          @pending_delta ||= @recorder.take_delta if accepted
          break if accepted && !@pending_delta && (@status.nil? || @status.flush)
          break if monotonic >= deadline || @status&.closed?

          @status&.io&.wait_writable((deadline - monotonic).clamp(0, 0.01))
        end
        until report("stopped", include_stats: false, exit_status: @exit_status) != false
          break if monotonic >= deadline || @status&.closed?

          @status.flush
          @status.io.wait_writable((deadline - monotonic).clamp(0, 0.01)) unless @status.closed?
        end
        @status.io.wait_writable((deadline - monotonic).clamp(0, 0.01)) until !@status || @status.flush || @status.closed? || monotonic >= deadline
      ensure
        begin
          cleanup { @recorder.close(timeout: [(deadline || monotonic) - monotonic, 0].max) }
          @signals&.close
          @admin&.close
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
