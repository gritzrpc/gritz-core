# frozen_string_literal: true

require "rbconfig"
require "tempfile"
require "timeout"
require "io/wait"

module Gritz
  module Testing
    # Starts a supervisor in a fresh interpreter, avoiding gRPC state inherited from a test process.
    # @api public
    class Cluster
      MAX_LOG_BYTES = 64 * 1024

      attr_reader :pid

      def self.start(**)
        cluster = new(**).start
        return cluster unless block_given?

        begin
          yield cluster
        ensure
          cluster.stop
        end
      end

      def initialize(config_path:, env: {}, command: nil)
        @config_path = File.expand_path(config_path)
        @env = env
        @command = command
        @status = { state: "starting", workers: [] }
      end

      def start
        raise ArgumentError, "cluster is already started" if @pid

        Supervisor::Launcher.enable_subreaper!
        @reader, writer = IO.pipe
        @channel = Supervisor::StatusChannel.new(@reader)
        @log = Tempfile.new(["gritz-cluster", ".log"])
        command = @command || [
          RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-rgritz/core", "-e",
          "exit Gritz::CLI.new(status_io: IO.for_fd(3), launch: true).run(ARGV)", "--", "start", "-C", @config_path
        ]
        @pid = Process.spawn(@env, *command, 3 => writer, out: @log, err: @log, pgroup: true)
        self
      rescue StandardError
        unless @pid
          @channel&.close
          @log&.close!
        end
        raise
      ensure
        writer&.close
      end

      def status
        @channel&.read&.each { |row| @status = row }
        @status
      end

      def workers = status.fetch(:workers, [])

      def master_pid = status[:pid] || @pid

      def logs
        return @logs || "" unless @log && !@log.closed?

        @log.flush
        File.open(@log.path) do |file|
          file.seek([file.size - MAX_LOG_BYTES, 0].max)
          file.read
        end
      end

      def signal(name, pid: @pid)
        raise ArgumentError, "cluster is not started" unless pid

        Process.kill(name, pid)
        self
      end

      # A predicate can inspect snapshots without fixed sleeps or dependence on log wording.
      def wait_until(state: "ready", workers: nil, timeout: 10)
        deadline = monotonic + timeout
        loop do
          snapshot = status
          active_workers = snapshot.fetch(:workers, []).reject { |worker| worker[:retiring] }
          ready = if state == "ready"
                    snapshot[:state] == "running" && active_workers.any? && active_workers.all? { |worker| worker[:state] == "ready" }
                  else
                    state.nil? || snapshot[:state] == state
                  end
          count = workers.nil? || active_workers.size == workers
          return self if ready && count && (!block_given? || yield(snapshot))

          if exited?
            raise "cluster exited #{@exit_status.inspect} before reaching #{state.inspect}\n#{logs}"
          end
          raise Timeout::Error, "cluster did not reach #{state.inspect}: #{snapshot.inspect}\n#{logs}" if monotonic >= deadline

          pause = (deadline - monotonic).clamp(0, 0.05)
          @reader.closed? ? sleep(pause) : @reader.wait_readable(pause)
        end
      end

      def wait(timeout: 10)
        raise ArgumentError, "cluster is not started" unless @pid

        deadline = monotonic + timeout
        until exited?
          raise Timeout::Error, "cluster did not exit\n#{logs}" if monotonic >= deadline

          sleep((deadline - monotonic).clamp(0, 0.01))
        end
        @exit_status
      end

      def stop(timeout: 10)
        return self unless @pid

        signal("TERM") unless exited?
        wait(timeout:)
        self
      rescue Timeout::Error
        signal("QUIT") if status[:owner_pid] && !exited?
        begin
          wait(timeout: 0.5)
        rescue Timeout::Error
          owned_groups.each { |pid| kill_group(pid) }
          wait(timeout: 5)
        end
        self
      ensure
        cleanup_groups if @pid && @exit_status
        @channel&.close
        @logs = logs
        @log&.close!
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def owned_groups
        [@pid, *status.fetch(:masters, []).map { |master| master[:pid] }].compact.uniq
      end

      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM
        # Darwin may report EPERM for an already-disappeared process group.
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          return
        end
        raise
      end

      def cleanup_groups
        groups = owned_groups.reject { |pid| pid == @pid }
        groups.each { |pid| kill_group(pid) }
        # Terminate every group before waiting for any adopted children.
        groups.each do |pid| # rubocop:disable Style/CombinableLoops
          loop { Process.waitpid(-pid) }
        rescue Errno::ECHILD
          nil
        end
        @status = @status.merge(masters: [])
      end

      def exited?
        return true if @exit_status
        return false unless @pid

        pair = Process.waitpid2(@pid, Process::WNOHANG)
        @exit_status = pair&.last
        !@exit_status.nil?
      end
    end
  end
end
