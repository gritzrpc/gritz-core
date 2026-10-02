# frozen_string_literal: true

module Gritz
  module Supervisor
    # Parent-owned worker state; heartbeat deadlines use the parent's monotonic clock.
    # @api private
    class WorkerHandle
      STATES = %w[booting ready draining failed stopped killed].freeze
      attr_reader :pid, :index, :channel, :born_at, :last_seen, :stats
      attr_accessor :state, :term_at, :kill_at, :recycle_factor, :restart_reason

      def initialize(pid:, index:, status_io:, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        @pid = pid
        @index = index
        @channel = StatusChannel.new(status_io)
        @born_at = @last_seen = now
        @state = "booting"
        @stats = {}
        @recycle_factor = 1.0
      end

      def update(message, now:)
        raise ConfigurationError, "Invalid worker state #{message[:state].inspect}" unless STATES.include?(message[:state])

        @last_seen = now
        @stats = @stats.slice(:rss_bytes, :pss_bytes).merge(message.except(:pid, :index, :state, :type, :metrics))
        # A late heartbeat must not undo the parent's decision to retire this worker.
        @state = message[:state] unless %w[draining killed].include?(@state)
      end

      def to_h = @stats.merge(pid: @pid, index: @index, state: @state, retiring: !@term_at.nil?, worker_started_at: @born_at)
      def close = @channel.close
    end
  end
end
