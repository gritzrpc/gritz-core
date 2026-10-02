# frozen_string_literal: true

module Gritz
  module Supervisor
    # Wakes the event loop without doing process or logger work in a signal trap.
    # @api private
    class SignalQueue
      attr_reader :io

      def initialize(signals:)
        @io, @writer = IO.pipe
        @pending = []
        @previous = {}
        signals.each do |name|
          @previous[name] = Signal.trap(name) do
            @pending << name unless @pending.include?(name)
            @writer.write_nonblock(".", exception: false)
          rescue IOError, Errno::EPIPE
            nil
          end
        end
      rescue StandardError
        close
        raise
      end

      def drain
        loop do
          break unless @io.read_nonblock(4096, exception: false).is_a?(String)
        end
        # Swap instead of clearing: a signal arriving here belongs to the next drain.
        pending = @pending
        @pending = []
        pending
      end

      def close
        @previous&.each { |name, handler| Signal.trap(name, handler) }
        @previous = {}
        close_in_child
      end

      def close_in_child
        @io&.close unless @io&.closed?
        @writer&.close unless @writer&.closed?
      end
    end
  end
end
