# frozen_string_literal: true

require "logger"

module Gritz
  module Supervisor
    # Forks workers, monitors their status pipes, and owns every child until reaped.
    # @api public
    class Master
      SIGNALS = %w[TERM INT QUIT TTIN TTOU HUP CHLD USR1 USR2].freeze
      attr_reader :workers

      def initialize(config, logger: Logger.new($stdout), status_io: nil, owner_channel: nil)
        @config = config
        @logger = logger
        @workers = {}
        @desired = config.workers
        @owner_channel = owner_channel
        @reports = owner_channel || (StatusChannel.new(status_io) if status_io)
        @metrics = Metrics::Aggregator.new
        @forwarded = []
        @replacement_queue = []
        @exit_status = 0
      end

      def run
        @config.validate_runtime!
        raise ConfigurationError, "Supervisor requires workers > 0" unless @desired.positive?

        require "gritz/native"
        @signals = SignalQueue.new(signals: SIGNALS)
        unless @owner_channel
          @admin = AdminServer.new(bind: @config.admin_bind, status: -> { status }, ready: -> { ready? },
                                   metrics: -> { @metrics.render(workers: @workers.values) }, logger: @logger)
        end
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
          sample_memory
          check_recycle
          advance_replacement
          maintain_worker_count unless @shutdown_at
          flush_forwarded
          @reports&.write { @owner_channel ? status.merge(type: "status") : status } if @forwarded.empty?
          @admin&.poll
          if @owner_channel&.closed?
            @exit_status = 1
            begin_shutdown(immediate: true)
          end
          if @shutdown_at && @workers.empty?
            break if !@owner_channel || @owner_channel.closed? || (@forwarded.empty? && @owner_channel.flush)
            break if now >= @shutdown_at + @config.drain_delay + @config.shutdown_timeout
          end

          worker_ios = @forwarded.empty? ? @workers.values.filter_map { |handle| handle.channel.io unless handle.channel.closed? } : []
          owner_ios = !@forwarded.empty? && @owner_channel && !@owner_channel.closed? ? [@owner_channel.io] : nil
          IO.select([@signals.io, *@admin&.ios.to_a, *worker_ios], owner_ios, nil, 0.05)
        end
        @exit_status
      ensure
        cleanup
        ForkGuard.deactivate if @guard
      end

      def status
        { pid: Process.pid, state: @shutdown_at ? "draining" : "running", desired: @desired,
          phased_restart: !@replacement.nil? || !@replacement_queue.empty?, workers: @workers.values.map(&:to_h) }
      end

      def ready?
        !@shutdown_at && @workers.values.count { |handle|
          handle.state == "ready" && !handle.term_at && handle.stats[:healthy] != false
        } >= @config.min_ready_workers
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def maintain_worker_count
        active = @workers.values.reject(&:term_at)
        used = active.map(&:index)
        (@desired - active.size).times do
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
            # Restore all inherited master traps, including CHLD and resize signals.
            @signals.close
            @reports&.close
            @admin&.close
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
        handle = WorkerHandle.new(pid: pid, index: index, status_io: reader)
        handle.recycle_factor = 1.0 + (rand * @config.worker_recycle.fetch(:jitter, 0.0))
        @workers[pid] = handle
        @logger.info("Worker #{index} spawned pid=#{pid}")
        handle
      rescue StandardError
        reader&.close unless reader&.closed?
        writer&.close unless writer&.closed?
        raise
      ensure
        Transport::Native.postfork_parent if prepared
      end

      def read_statuses
        @workers.each_value do |handle|
          break unless @forwarded.empty?

          consume_status(handle, handle.channel.read)
          flush_forwarded
        end
      end

      def consume_status(handle, rows)
        rows.each do |message|
          if message[:type] == "metrics"
            if @metrics.apply(handle, message) && @owner_channel
              @forwarded << message.merge(pid: Process.pid, worker_pid: handle.pid, worker_started_at: handle.born_at)
            end
            next
          end
          handle.update(message, now: now)
          if message[:state] == "failed" && !@ever_ready
            @exit_status = 1
            begin_shutdown
          end
          @ever_ready = true if message[:state] == "ready"
        rescue ConfigurationError => e
          @logger.error("Worker #{handle.pid}: #{e.message}")
          kill(handle)
        end
      end

      def flush_forwarded
        return unless @owner_channel

        @owner_channel.flush
        @forwarded.shift while !@forwarded.empty? && @owner_channel.write(@forwarded.first)
      end

      def reap_children
        # Keep a reaped worker's bounded pipe tail queued until owner backpressure clears.
        return unless @forwarded.empty? || @owner_channel&.closed?

        # Only reap owned children: application hooks can start unrelated subprocesses.
        @workers.each_key do |pid|
          result = Process.waitpid2(pid, Process::WNOHANG)
          next unless result

          handle = @workers.fetch(pid)
          # A forked application subprocess can retain the writer after the worker exits.
          # Drain the bytes present at reap time without waiting for that subprocess's EOF.
          available = 0
          unless handle.channel.closed?
            size = [0].pack("i")
            # FIONREAD reports queued bytes; Ruby 4.0 removed IO#nread.
            handle.channel.io.ioctl(RUBY_PLATFORM.include?("linux") ? 0x541B : 0x4004667F, size)
            available = size.unpack1("i")
          end
          if available.zero?
            consume_status(handle, handle.channel.read)
          end
          while available.positive?
            bytes = [available, StatusChannel::MAX_READ_BYTES].min
            consume_status(handle, handle.channel.read(max_bytes: bytes))
            available -= bytes
            break if handle.channel.closed?
          end
          @workers.delete(pid)
          @metrics.forget(handle)
          handle.close
          child_status = result.last
          @logger.info("Worker #{handle.index} exited pid=#{pid} status=#{child_status}")
          startup_failed = (child_status.exited? || child_status.termsig != Signal.list.fetch("KILL")) && !@ever_ready && !@shutdown_at && !handle.term_at
          shutdown_failed = @shutdown_at && !child_status.success?
          if handle.state != "killed" && (startup_failed || shutdown_failed)
            @exit_status = 1
            begin_shutdown(immediate: true) if startup_failed
          end
          if !@shutdown_at && !handle.term_at && @workers.values.count { |worker| !worker.term_at } < @desired
            record_restart(handle.restart_reason || "worker_exit")
          end
          break unless @forwarded.empty?
        rescue Errno::ECHILD
          @workers.delete(pid)&.close
        end
      end

      def handle_signal(signal)
        case signal
        when "TERM", "INT" then begin_shutdown
        when "QUIT" then begin_shutdown(immediate: true)
        when "TTIN"
          if @replacement || !@replacement_queue.empty?
            @logger.warn("Wait for phased restart before resizing workers")
          elsif !@shutdown_at && @config.bind.end_with?(":0")
            @logger.warn("Cannot add a reuseport worker with port 0; configure a fixed bind port")
          elsif !@shutdown_at
            @desired += 1
          end
        when "TTOU"
          if @replacement || !@replacement_queue.empty?
            @logger.warn("Wait for phased restart before resizing workers")
          elsif !@shutdown_at && @desired > 1
            @desired -= 1
            retire(@workers.values.reject(&:term_at).max_by(&:index), delay: 0)
          end
        when "HUP"
          @logger.reopen
          @workers.each_key { |pid| send_signal("HUP", pid) }
          @logger.info("Log reopened")
        when "USR1"
          if fixed_port? && !@shutdown_at && !@replacement && @replacement_queue.empty?
            @replacement_queue = @workers.values.reject(&:term_at).sort_by(&:index).map { |handle| [handle.pid, "phased_restart"] }
          end
        when "USR2"
          if fixed_port? && !@shutdown_at
            if @owner_channel
              @forwarded << { type: "reexec", pid: Process.pid } unless @forwarded.any? { |row| row[:type] == "reexec" }
            else
              @logger.warn("USR2 requires the gritz launcher")
            end
          end
        end
      end

      def begin_shutdown(immediate: false)
        @shutdown_at ||= now
        @replacement_queue.clear
        @replacement = nil
        if immediate
          @workers.each_value { |handle| kill(handle) }
        else
          @workers.each_value { |handle| retire(handle) unless handle.term_at }
        end
      end

      def retire(handle, delay: @config.drain_delay)
        return unless handle

        handle.term_at = now + delay
        handle.state = "draining"
        send_signal("USR1", handle.pid)
      end

      def fixed_port?
        return true unless @config.bind.end_with?(":0")

        @logger.warn("Worker replacement requires a fixed bind port")
        false
      end

      def advance_replacement
        return if @shutdown_at || !@forwarded.empty?

        if @replacement
          old = @workers[@replacement[:old]]
          fresh = @workers[@replacement[:new]]
          if !fresh || %w[failed stopped killed].include?(fresh.state) ||
             (!@replacement[:retired] && now - @replacement[:started] > @config.worker_boot_timeout)
            kill(fresh) if fresh
            @logger.warn("Replacement failed; keeping previous workers")
            @replacement = nil
            @replacement_queue.clear
            @recycle_retry_at = now + @config.worker_boot_timeout
            return true
          end
          if !@replacement[:retired] && fresh.state == "ready" && fresh.stats[:healthy] != false
            retire(old) if old
            reason = @replacement[:reason]
            record_restart(reason)
            @replacement[:retired] = true
          end
          return if old || !@replacement[:retired]

          @replacement = nil
        end
        while (entry = @replacement_queue.shift)
          old_pid, reason = entry
          old = @workers[old_pid]
          next unless old && !old.term_at

          fresh = spawn_worker(old.index)
          @replacement = { old: old_pid, new: fresh.pid, reason: reason, started: now, retired: false }
          break
        end
      end

      def check_recycle
        return if @shutdown_at || @replacement || !@replacement_queue.empty? || @config.worker_recycle.empty?
        return if @recycle_retry_at && now < @recycle_retry_at
        return if @config.bind.end_with?(":0")

        @workers.each_value do |handle|
          next unless handle.state == "ready" && !handle.term_at

          @config.worker_recycle.each do |name, limit|
            value = case name
                    when :max_requests then handle.stats[:requests_total]
                    when :max_rss_mb then handle.stats[:rss_bytes]&./(1024.0 * 1024)
                    when :max_pss_mb then handle.stats[:pss_bytes]&./(1024.0 * 1024)
                    when :max_lifetime then now - handle.born_at
                    end
            next unless value && value >= limit * handle.recycle_factor

            @replacement_queue << [handle.pid, name.to_s]
            return true
          end
        end
      end

      def sample_memory
        return unless RUBY_PLATFORM.include?("linux")
        return if @next_memory_at && now < @next_memory_at

        @next_memory_at = now + @config.status_interval
        @workers.each_value do |handle|
          data = File.read("/proc/#{handle.pid}/smaps_rollup")
          handle.stats[:rss_bytes] = data[/^Rss:\s+(\d+)/, 1].to_i * 1024
          handle.stats[:pss_bytes] = data[/^Pss:\s+(\d+)/, 1].to_i * 1024
        rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
          next
        end
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
          elsif !@shutdown_at && !handle.term_at
            # An unconsumed heartbeat is not evidence of a stuck worker.
            next if handle.state != "booting" && !@forwarded.empty?

            elapsed = timestamp - (handle.state == "booting" ? handle.born_at : handle.last_seen)
            timeout = handle.state == "booting" ? @config.worker_boot_timeout : @config.worker_timeout
            if elapsed > timeout
              @logger.error("Worker #{handle.pid} #{handle.state} timeout after #{elapsed.round(2)}s")
              handle.restart_reason = handle.state == "booting" ? "worker_boot_timeout" : "worker_timeout"
              kill(handle)
            end
          end
        end
      end

      def kill(handle)
        handle.state = "killed"
        send_signal("KILL", handle.pid)
      end

      def record_restart(reason)
        @metrics.record_restart(reason: reason)
        @forwarded << { type: "restart", pid: Process.pid, reason: reason } if @owner_channel
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
        @admin&.close
        flush_forwarded
        @reports&.close
      end
    end
  end
end
