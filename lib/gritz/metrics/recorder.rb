# frozen_string_literal: true

require "json"

module Gritz
  module Metrics
    # Per-worker RPC deltas; only one bounded detached batch is needed by the sender.
    # @api private
    class Recorder
      DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, Float::INFINITY].freeze
      MESSAGE_BUCKETS = [0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 1024, Float::INFINITY].freeze
      SCALARS = %i[count duration_sum request_sum response_sum].freeze
      BUCKET_FIELDS = %i[duration_buckets request_buckets response_buckets].freeze

      def initialize
        @lock = Mutex.new
        @rpc = {}
        @last_rejected = @rejected_delta = 0
      end

      def self.empty_row(service:, method:, code:)
        { service: service.dup.freeze, method: method.dup.freeze, code: code, count: 0, duration_sum: 0.0, request_sum: 0, response_sum: 0,
          duration_buckets: Array.new(DURATION_BUCKETS.size, 0), request_buckets: Array.new(MESSAGE_BUCKETS.size, 0),
          response_buckets: Array.new(MESSAGE_BUCKETS.size, 0) }
      end

      def record_rpc(service:, method:, code:, duration:, requests:, responses:)
        unless [service, method].all? { |label| label.is_a?(String) && !label.empty? } && code.is_a?(Integer) && code.between?(0, 16) &&
               duration.is_a?(Numeric) && duration.real? && duration.to_f.finite? && duration >= 0 &&
               [requests, responses].all? { |value| value.is_a?(Integer) && value >= 0 }
          raise ArgumentError, "Invalid RPC metric observation"
        end

        @lock.synchronize do
          row = @rpc[[service, method, code]]
          unless row
            row = self.class.empty_row(service: service, method: method, code: code)
            @rpc[[row[:service], row[:method], code].freeze] = row
          end
          row[:count] += 1
          row[:duration_sum] += duration.to_f
          row[:request_sum] += requests
          row[:response_sum] += responses
          row[:duration_buckets][DURATION_BUCKETS.bsearch_index { |upper| duration <= upper }] += 1
          row[:request_buckets][MESSAGE_BUCKETS.bsearch_index { |upper| requests <= upper }] += 1
          row[:response_buckets][MESSAGE_BUCKETS.bsearch_index { |upper| responses <= upper }] += 1
        end
      end

      def observe_rejected(total)
        @lock.synchronize do
          raise ArgumentError, "Rejected counter must be a nondecreasing integer" unless total.is_a?(Integer) && total >= @last_rejected

          @rejected_delta += total - @last_rejected
          @last_rejected = total
        end
      end

      # The caller retains this detached delta until its status channel accepts the row.
      def take_delta(max_bytes: Supervisor::StatusChannel::MAX_LINE_BYTES - 4096)
        raise ArgumentError, "Metric packet budget must be positive" unless max_bytes.is_a?(Integer) && max_bytes.positive?

        @lock.synchronize do
          return nil if @rpc.empty? && @rejected_delta.zero?

          delta = { rpc: [], rejected: @rejected_delta }
          used_bytes = JSON.generate(delta).bytesize
          raise ArgumentError, "Metric packet budget is too small" if used_bytes > max_bytes

          selected = []
          @rpc.each do |key, row|
            row_bytes = JSON.generate(row).bytesize + (selected.empty? ? 0 : 1)
            if used_bytes + row_bytes > max_bytes
              raise ArgumentError, "Metric row exceeds the packet budget" if selected.empty?

              break
            end
            delta[:rpc] << row
            selected << key
            used_bytes += row_bytes
          end
          selected.each { |key| @rpc.delete(key) }
          @rejected_delta = 0
          delta
        end
      end
    end
  end
end
