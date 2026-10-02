# frozen_string_literal: true

require "logger"

module Gritz
  module Supervisor
    # Forks workers, monitors their status pipes, and owns every child until reaped.
    # @api public
    class Master
      SIGNALS = %w[TERM INT QUIT TTIN TTOU HUP CHLD].freeze
      attr_reader :workers

      def initialize(config, logger: Logger.new($stdout), status_io: nil)
        @config = config
        @logger = logger
        @workers = {}
        @desired = config.workers
        @reports = StatusChannel.new(status_io) if status_io
        @exit_status = 0
      end

      def run
        @config.validate_runtime!
        raise ConfigurationError, "Supervisor requires workers > 0" unless @desired.positive?

        require "gritz/native"
        @signals = SignalQueue.new(signals: SIGNALS)
        @guard = ForkGuard.activate(mode: @config.fork_mode == :clean ? @config.fork_guard : :off, logger: @logger)
        @config.preload! if @config.preload_app?
        Process.warmup if @config.preload_app? && Process.respond_to?(:warmup)
        if @config.workers > 1 && !RUBY_PLATFORM.include?("linux")
          @logger.warn("Multiple native workers require Linux for SO_REUSEPORT load balancing; use workers 0 on macOS")
        end
        maintain_worker_count
        loop do
          @signals.drain.each { |signal| handle_signal(signal) }
          read_statuses
          reap_children
          check_timeouts
          maintain_worker_count unless @shutdown_at
          @reports&.write(status)
          break if @shutdown_at && @workers.empty?

          IO.select([@signals.io, *@workers.values.filter_map { |handle| handle.channel.io unless handle.channel.closed? }], nil, nil, 0.05)
        end
        @exit_status
      ensure
        cleanup
        ForkGuard.deactivate if @guard
      end

      def status
        { pid: Process.pid, state: @shutdown_at ? "draining" : "running", workers: @workers.values.map(&:to_h) }
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def maintain_worker_count
        used = @workers.values.map(&:index)
        (@desired - @workers.size).times do
          index = (0...@desired).find { |candidate| !used.include?(candidate) }
          spawn_worker(index)
          used << index
        end
      end

      def spawn_worker(index)
        reader, writer = IO.pipe
        @config.run_hooks(:before_fork, index)
        experimental = @config.fork_mode == :grpc_fork_support
        if experimental
          require "gritz/native"
          Transport::Native.prefork
          prepared = true
        end
        pid = Process.fork do
          exit_status = 1
          begin
            reader.close
            @signals.close_in_child
            @reports&.close
            @workers.each_value(&:close)
            Transport::Native.postfork_child if experimental
            exit_status = Worker::Runner.new(index: index, status_io: writer, config: @config, logger: @logger).run
          rescue StandardError, LoadError, SyntaxError, SystemExit => e
            @logger.error("Worker #{index} failed: #{e.full_message}")
            exit_status = 1
          ensure
            begin
              writer.close unless writer.closed?
            ensure
              # Never unwind the inherited master ensure or run application at_exit hooks.
              Process.exit!(exit_status)
            end
          end
        end
        writer.close
        @workers[pid] = WorkerHandle.new(pid: pid, index: index, status_io: reader)
        @logger.info("Worker #{index} spawned pid=#{pid}")
      rescue StandardError
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        raise
      ensure
        Transport::Native.postfork_parent if prepared
      end

      def read_statuses
        @workers.each_value do |handle|
          handle.channel.read.each do |message|
            handle.update(message, now: now)
            if message[:state] == "failed" && !@ever_ready
              @exit_status = 1
              begin_shutdown(immediate: true)
            end
            @ever_ready = true if message[:state] == "ready"
          rescue ConfigurationError => e
            @logger.error("Worker #{handle.pid}: #{e.message}")
            kill(handle)
          end
        end
      end

      def reap_children
        # Only reap owned children: application hooks can start unrelated subprocesses.
        @workers.each_key do |pid|
          result = Process.waitpid2(pid, Process::WNOHANG)
          next unless result

          handle = @workers.delete(pid)
          handle.close
          @logger.info("Worker #{handle.index} exited pid=#{pid} status=#{result.last}")
        rescue Errno::ECHILD
          @workers.delete(pid)&.close
        end
      end

      def handle_signal(signal)
        case signal
        when "TERM", "INT" then begin_shutdown
        when "QUIT" then begin_shutdown(immediate: true)
        when "TTIN"
          if !@shutdown_at && @config.bind.end_with?(":0")
            @logger.warn("Cannot add a reuseport worker with port 0; configure a fixed bind port")
          elsif !@shutdown_at
            @desired += 1
          end
        when "TTOU"
          if !@shutdown_at && @desired > 1
            @desired -= 1
            retire(@workers.values.reject(&:term_at).max_by(&:index))
          end
        when "HUP"
          @logger.reopen
          @workers.each_key { |pid| send_signal("HUP", pid) }
          @logger.info("Log reopened")
        end
      end

      def begin_shutdown(immediate: false)
        @shutdown_at ||= now
        if immediate
          @workers.each_value { |handle| kill(handle) }
        else
          @workers.each_value { |handle| handle.term_at ||= @shutdown_at + @config.drain_delay }
        end
      end

      def retire(handle)
        return unless handle

        handle.term_at = now
        handle.state = "draining"
      end

      def check_timeouts
        timestamp = now
        @workers.each_value do |handle|
          next if handle.state == "killed"

          if handle.term_at && timestamp >= handle.term_at && !handle.kill_at
            handle.state = "draining"
            send_signal("TERM", handle.pid)
            handle.kill_at = timestamp + @config.shutdown_timeout
          end
          if handle.kill_at
            kill(handle) if timestamp >= handle.kill_at
          elsif !@shutdown_at
            elapsed = timestamp - (handle.state == "booting" ? handle.born_at : handle.last_seen)
            timeout = handle.state == "booting" ? @config.worker_boot_timeout : @config.worker_timeout
            if elapsed > timeout
              @logger.error("Worker #{handle.pid} #{handle.state} timeout after #{elapsed.round(2)}s")
              kill(handle)
            end
          end
        end
      end

      def kill(handle)
        handle.state = "killed"
        send_signal("KILL", handle.pid)
      end

      def send_signal(signal, pid)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      def cleanup
        @workers.each_value { |handle| kill(handle) }
        @workers.each_value do |handle| # rubocop:disable Style/CombinableLoops -- kill every child before waiting for any child
          Process.waitpid(handle.pid)
        rescue Errno::ECHILD
          nil
        ensure
          handle.close
        end
        @workers.clear
        @signals&.close
        @reports&.close
      end
    end
  end
end
