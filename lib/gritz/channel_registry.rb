# frozen_string_literal: true

module Gritz
  # Shares transport connections within a process, never across a fork.
  # @api private
  class ChannelRegistry
    module ForkHook
      def _fork(...)
        result = super
        Gritz::ChannelRegistry.reset! if result.zero?
        result
      end
    end

    class << self
      def fetch(target:, credentials:, args: {}, pool: nil)
        reset! unless @pid == Process.pid
        key = [Process.pid, pool, snapshot(target), credentials, snapshot(args)].freeze
        @lock.synchronize { @channels.fetch(key) { @channels[key] = yield } }
      end

      # In a child, discard references without calling native close methods.
      def reset!
        @lock = Mutex.new
        @channels = {}
        @pid = Process.pid
      end

      def snapshot(value)
        case value
        when String then value.dup.freeze
        when Array then value.map { |entry| snapshot(entry) }.freeze
        when Hash then value.to_h { |key, entry| [snapshot(key), snapshot(entry)] }.freeze
        else value
        end
      end
    end

    reset!
    Process.singleton_class.prepend(ForkHook) unless Process.singleton_class.ancestors.include?(ForkHook)
  end
end
