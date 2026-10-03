# frozen_string_literal: true

require "socket"
require "fileutils"
require "tempfile"

module Gritz
  module Supervisor
    # Keeps process ownership and probes stable while fresh master interpreters replace each other.
    # @api private
    class Launcher
      Generation = Struct.new(:pid, :channel, :token, :role, :metadata, :snapshot, :started_at, :deadline,
                              :kill_at, :kill_sent, :exit_status, :group_reaped, :identities, keyword_init: true)
      SIGNALS = %w[TERM INT QUIT USR1 USR2 TTIN TTOU HUP CHLD].freeze

      def self.enable_subreaper!
        return unless RUBY_PLATFORM.include?("linux")

        require "fiddle"
        function = Fiddle::Function.new(Fiddle.dlopen(nil)["prctl"],
                                        [Fiddle::TYPE_INT, *Array.new(4, Fiddle::TYPE_LONG)], Fiddle::TYPE_INT)
        raise "Cannot enable child process reaping" unless function.call(36, 1, 0, 0, 0).zero?
      end

      def initialize(command:, logger:, env: ENV, stdout: $stdout, stderr: $stderr, status_io: nil, startup_timeout: 60)
        @command = command
        @logger = logger
        @env = env
        @stdout = stdout
        @stderr = stderr
        @observer = StatusChannel.new(status_io) if status_io
        @startup_timeout = startup_timeout
        @generations = {}
        @serial = 0
        @metrics = Metrics::Aggregator.new
        @exit_code = 0
      end

      def run
        self.class.enable_subreaper!
        @signals = SignalQueue.new(signals: SIGNALS)
        spawn_generation
        loop do
          @signals.drain.each { |name| handle_signal(name) }
          # Reading a reexec request can add a generation, so iterate a stable snapshot.
          @generations.values.each do |generation| # rubocop:disable Style/HashEachMethods
            read_generation(generation)
            reap_generation(generation)
          end
          update_lifecycle
          @admin&.poll
          @observer&.write { status }
          @observer&.flush
          break if @stopping && @generations.empty?

          ios = [@signals.io, *@generations.values.reject { |generation| generation.channel.closed? }.map { |generation| generation.channel.io },
                 *@admin&.ios].compact
          IO.select(ios, nil, nil, 0.02)
        end
        @exit_code
      rescue StandardError => e
        @logger.error("Launcher failed: #{e.message}")
        1
      ensure
        cleanup
      end

      def status
        active = @active&.snapshot || {}
        pools = @generations.values.select { |generation| %i[active retiring].include?(generation.role) || (!@active && generation == @candidate) }
        workers = pools.flat_map do |generation|
          generation.snapshot&.fetch(:workers, [])&.map do |worker|
            worker.merge(master_pid: generation.pid, retiring: generation.role == :retiring || worker[:retiring] == true)
          end || []
        end
        state = if @stopping
                  "draining"
                elsif @active
                  "running"
                else
                  "starting"
                end
        active.merge(owner_pid: Process.pid, pid: (@active || @candidate)&.pid, state: state,
                     workers: workers, ready_workers: ready_workers(@active), admin_address: @admin&.address,
                     masters: @generations.values.map { |generation| { pid: generation.pid, state: generation.role.to_s } }, reexec: @reexec)
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def spawn_generation
        parent, child = UNIXSocket.pair
        started_at = monotonic
        pid = Process.spawn(@env.to_h.merge("GRITZ_INTERNAL_OWNER_FD" => "3"), *@command,
                            3 => child, out: @stdout, err: @stderr, pgroup: true)
        @serial += 1
        @candidate = Generation.new(pid: pid, channel: StatusChannel.new(parent), token: @serial, role: :candidate,
                                    started_at:, deadline: started_at + @startup_timeout, identities: {})
        @generations[pid] = @candidate
        @reexec = { state: "starting", pid: pid } if @active
      rescue StandardError
        parent&.close
        raise
      ensure
        child&.close
      end

      def read_generation(generation)
        generation.channel.read.each do |row|
          next unless row[:pid] == generation.pid

          case row[:type]
          when "configured" then configure_generation(generation, row)
          when "status"
            generation.snapshot = row.except(:type)
            live_pids = row.fetch(:workers, []).map { |worker| worker[:pid] }
            generation.identities.delete_if do |pid, key|
              next false if live_pids.include?(pid)

              @metrics.forget(key)
              true
            end
          when "reexec" then request_reexec if generation == @active
          when "restart" then @metrics.record_restart(reason: row[:reason])
          when "metrics"
            previous = generation.identities[row[:worker_pid]]
            key = [generation.token, row[:worker_pid], row[:worker_started_at]].freeze
            @metrics.forget(previous) if previous && previous != key
            generation.identities[row[:worker_pid]] = key
            @metrics.apply(key, row.slice(:seq, :delta))
          end
        end
      rescue ConfigurationError, ArgumentError, SystemCallError => e
        fail_candidate(e.message) if generation == @candidate
        @logger.error("Master #{generation.pid}: #{e.message}")
      end

      def configure_generation(generation, metadata)
        return if generation.metadata || @stopping
        raise ConfigurationError, "replacement master configuration timed out" if monotonic >= generation.deadline

        if metadata[:listener_strategy] && !%w[reuseport inherited_fd].include?(metadata[:listener_strategy])
          raise ConfigurationError, "Invalid master listener_strategy"
        end

        %i[admin_bind bind pid_file].each do |field|
          raise ConfigurationError, "Missing master #{field}" unless metadata[field].is_a?(String)
        end
        %i[workers min_ready_workers].each do |field|
          raise ConfigurationError, "Invalid master #{field}" unless metadata[field].is_a?(Integer) && metadata[field] >= 0
        end
        %i[reexec_timeout drain_delay shutdown_timeout].each do |field|
          value = metadata[field]
          raise ConfigurationError, "Invalid master #{field}" unless value.is_a?(Numeric) && value.finite? && value >= 0
        end
        if @metadata
          %i[admin_bind bind pid_file listener_strategy].each do |field|
            raise ConfigurationError, "USR2 cannot change #{field}" unless metadata[field] == @metadata[field]
          end
        else
          @metadata = metadata
          @admin = AdminServer.new(bind: metadata[:admin_bind], status: -> { status }, ready: -> { ready? },
                                   metrics: -> { @metrics.render(workers: status[:workers]) }, logger: @logger)
          lock_pid_file(metadata[:pid_file]) unless metadata[:pid_file].empty?
        end
        generation.metadata = metadata
        generation.deadline = generation.started_at + metadata[:reexec_timeout]
        if metadata[:listener_strategy] == "inherited_fd"
          @listener ||= Listener.bind(metadata[:bind])
          generation.channel.io.send_io(@listener)
        end
      end

      def ready_workers(generation)
        return 0 unless generation&.snapshot&.dig(:state) == "running"

        generation.snapshot.fetch(:workers, []).count do |worker|
          worker[:state] == "ready" && worker[:healthy] != false && worker[:retiring] != true
        end
      end

      def booted_workers(generation)
        return 0 unless generation&.snapshot&.dig(:state) == "running"

        generation.snapshot.fetch(:workers, []).count { |worker| worker[:state] == "ready" && worker[:retiring] != true }
      end

      def ready?
        !@stopping && @active && ready_workers(@active) >= @active.metadata[:min_ready_workers]
      end

      def request_reexec
        return if @stopping

        if @candidate || @generations.values.any? { |generation| generation.role == :retiring }
          @pending_reexec = true
          return
        end

        if @active.metadata[:bind].end_with?(":0") && !@listener
          @reexec = { state: "failed", error: "USR2 requires a fixed RPC port" }
          @logger.warn(@reexec[:error])
          return
        end
        spawn_generation
      rescue StandardError => e
        @reexec = { state: "failed", error: e.message }
        @logger.error("USR2 failed: #{e.message}")
      end

      def update_lifecycle
        if @candidate&.role == :candidate
          if @candidate.exit_status
            fail_candidate("replacement master exited before readiness", force: false)
          elsif @candidate.channel.closed?
            fail_candidate("replacement master closed its control channel before readiness", force: false)
          elsif monotonic >= @candidate.deadline
            fail_candidate("replacement master readiness timed out")
          elsif @candidate.metadata && (@active ? ready_workers(@candidate) : booted_workers(@candidate)) >= [@candidate.metadata[:workers], 1].max
            promote_candidate
          end
        end
        if @active&.exit_status && !@stopping
          begin_shutdown(code: @active.exit_status.success? ? 0 : 1)
        elsif @active&.snapshot&.dig(:state) == "draining" && !@stopping
          begin_shutdown
        end
        if @active&.exit_status&.exited? && !@active.exit_status.success?
          @exit_code = 1
        end
        @generations.each_value do |generation|
          kill_group(generation) if generation.kill_at && monotonic >= generation.kill_at
          next unless generation.group_reaped && generation.channel.closed?

          generation.identities.each_value { |key| @metrics.forget(key) }
          @generations.delete(generation.pid)
          @candidate = nil if @candidate == generation
        end
        if @pending_reexec && !@stopping && !@candidate && @generations.values.none? { |generation| generation.role == :retiring }
          @pending_reexec = false
          request_reexec
        end
      end

      def promote_candidate
        replacement = @candidate
        write_pid(replacement.pid)
        if @active
          @active.role = :retiring
          terminate(@active)
          @metrics.record_restart(reason: "hot_reexec")
          @reexec = { state: "complete", pid: replacement.pid }
        end
        replacement.role = :active
        @active = replacement
        @candidate = nil
      rescue StandardError => e
        fail_candidate(e.message)
      end

      def fail_candidate(message, force: true)
        return unless @candidate

        @candidate.role = :failed
        if force
          kill_group(@candidate)
        else
          @candidate.kill_at = monotonic + 1
        end
        @reexec = { state: "failed", error: message }
        @logger.error("USR2 failed: #{message}")
        unless @active
          @exit_code = 1
          @stopping = true
        end
      end

      def reap_generation(generation)
        reap_exited_group(generation)
        kill_group(generation) if generation.exit_status && !generation.group_reaped
      end

      def reap_exited_group(generation)
        loop do
          result = Process.waitpid2(-generation.pid, Process::WNOHANG)
          break unless result

          generation.exit_status = result.last if result.first == generation.pid
        end
      rescue Errno::ECHILD
        generation.group_reaped = true
      end

      def handle_signal(name)
        case name
        when "TERM", "INT" then begin_shutdown
        when "QUIT"
          @stopping = true
          @candidate.role = :stopping if @candidate
          @generations.each_value { |generation| kill_group(generation) }
        when "USR2" then request_reexec if @active
        when "HUP"
          @logger.reopen if @logger.respond_to?(:reopen)
          @generations.each_value { |generation| signal_generation(generation, name) if %i[active retiring].include?(generation.role) }
        when "USR1"
          if @active && !@stopping
            if @active.metadata[:workers].zero?
              @logger.warn("USR1 requires worker processes; use USR2 to reload a single-process server")
            else
              signal_generation(@active, name)
            end
          end
        when "TTIN", "TTOU" then signal_generation(@active, name) if @active && !@stopping
        end
      end

      def begin_shutdown(code: 0)
        @exit_code = code if code != 0
        return if @stopping

        @stopping = true
        @generations.each_value do |generation|
          generation.role = :stopping if generation.role == :candidate
          terminate(generation)
        end
      end

      def terminate(generation)
        signal_generation(generation, "TERM")
        metadata = generation.metadata || {}
        generation.kill_at = monotonic + metadata.fetch(:drain_delay, 0) + metadata.fetch(:shutdown_timeout, 1) + 1
      end

      def signal_generation(generation, name)
        Process.kill(name, generation.pid) unless generation.exit_status
      rescue Errno::ESRCH
        nil
      end

      def kill_group(generation)
        reap_exited_group(generation)
        return if generation.group_reaped || generation.kill_sent

        Process.kill("KILL", -generation.pid)
        generation.kill_sent = true
        generation.kill_at = nil
      rescue Errno::ESRCH
        generation.kill_sent = true
      end

      def lock_pid_file(path)
        @pid_path = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(@pid_path))
        @pid_lock = File.open("#{@pid_path}.lock", File::RDWR | File::CREAT, 0o644)
        raise ConfigurationError, "PID file is already owned: #{@pid_path}" unless @pid_lock.flock(File::LOCK_EX | File::LOCK_NB)
      end

      def write_pid(pid)
        return unless @pid_path

        Tempfile.create([".gritz-pid", ".tmp"], File.dirname(@pid_path)) do |file|
          file.write("#{pid}\n")
          file.flush
          File.rename(file.path, @pid_path)
        end
        @written_pid = pid
      end

      def cleanup
        @generations.each_value do |generation|
          kill_group(generation)
          generation.channel.close
          begin
            loop { Process.waitpid(-generation.pid) }
          rescue Errno::ECHILD
            nil
          end
        end
        @generations.clear
        @admin&.close
        @observer&.close
        @signals&.close
        @listener&.close
        if @written_pid && File.file?(@pid_path) && File.read(@pid_path).strip == @written_pid.to_s
          File.unlink(@pid_path)
        end
        @pid_lock&.close
      end
    end
  end
end
