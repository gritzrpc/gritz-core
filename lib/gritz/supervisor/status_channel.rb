# frozen_string_literal: true

require "json"

module Gritz
  module Supervisor
    # Bounded, nonblocking JSON Lines over a worker's dedicated status pipe.
    # @api private
    class StatusChannel
      # ponytail: master snapshots are capped at 64 KiB; chunk reports if clusters outgrow this bound.
      MAX_LINE_BYTES = 64 * 1024
      MAX_READ_BYTES = 64 * 1024

      attr_reader :io

      def initialize(io)
        @io = io
        @buffer = +""
        @pending = +""
        @discarding = false
        @closed = io.closed?
      end

      def write(status = nil)
        return false if closed? || flush_pending.positive?

        status = yield if block_given?
        line = "#{JSON.generate(status)}\n"
        return false if line.bytesize > MAX_LINE_BYTES

        @pending = line
        flush_pending
        true
      rescue JSON::GeneratorError, JSON::NestingError
        false
      rescue IOError, SystemCallError
        close
        false
      end

      # True means the accepted record is fully delivered; false means retry later.
      def flush
        return false if closed?

        flush_pending.zero?
      rescue IOError, SystemCallError
        close
        false
      end

      def read(max_bytes: MAX_READ_BYTES)
        rows = []
        return rows if closed?
        raise ArgumentError, "Invalid status read budget" unless max_bytes.is_a?(Integer) && max_bytes.between?(1, MAX_READ_BYTES)

        remaining = max_bytes
        while remaining.positive?
          chunk = @io.read_nonblock([4096, remaining].min, exception: false)
          break if chunk == :wait_readable

          if chunk.nil?
            close
            break
          end

          remaining -= chunk.bytesize
          consume(chunk, rows)
        end
        rows
      rescue IOError, SystemCallError
        close
        rows
      end

      def closed? = @closed || @io.closed?

      def close
        @closed = true
        @buffer.clear
        @pending.clear
        @io.close unless @io.closed?
        nil
      rescue IOError
        nil
      end

      private

      def flush_pending
        return 0 if @pending.empty?

        written = @io.write_nonblock(@pending, exception: false)
        return @pending.bytesize if written == :wait_writable

        @pending = @pending.byteslice(written..) || +""
        @pending.bytesize
      end

      def consume(chunk, rows)
        chunk.each_line do |part|
          complete = part.end_with?("\n")
          unless @discarding
            @buffer << part
            if @buffer.bytesize > MAX_LINE_BYTES
              @buffer.clear
              @discarding = true
            end
          end
          next unless complete

          unless @discarding
            begin
              row = JSON.parse(@buffer, symbolize_names: true)
              rows << row if row.is_a?(Hash)
            rescue JSON::ParserError
              # A damaged record does not prevent subsequent status updates.
            end
          end
          @buffer.clear
          @discarding = false
        end
      end
    end
  end
end
