# frozen_string_literal: true

module Gritz
  module Metrics
    # Master-owned totals survive worker retirement; only replay state is forgotten.
    # @api private
    class Aggregator
      def initialize
        @lock = Mutex.new
        @rpc = {}
        @sequences = {}
        @rejected = 0
        @restarts = Hash.new(0)
      end

      def apply(worker, envelope)
        unless envelope.is_a?(Hash) && envelope[:seq].is_a?(Integer) && envelope[:seq].positive?
          raise ConfigurationError, "Invalid metric sequence"
        end

        @lock.synchronize do
          sequence = envelope[:seq]
          previous = @sequences.fetch(worker, 0)
          return false if sequence <= previous
          raise ConfigurationError, "Metric sequence gap: expected #{previous + 1}, got #{sequence}" unless sequence == previous + 1

          delta = envelope[:delta]
          validate_delta!(delta)
          delta[:rpc].each do |row|
            labels = row.slice(:service, :method, :code)
            aggregate = @rpc[labels.values]
            unless aggregate
              aggregate = Recorder.empty_row(**labels)
              @rpc[aggregate.values_at(:service, :method, :code).freeze] = aggregate
            end
            Recorder::SCALARS.each { |field| aggregate[field] += row[field] }
            Recorder::BUCKET_FIELDS.each do |field|
              row[field].each_with_index { |count, index| aggregate[field][index] += count }
            end
          end
          @rejected += delta[:rejected]
          @sequences[worker] = sequence
          true
        end
      end

      def forget(worker) = @lock.synchronize { @sequences.delete(worker) }

      def record_restart(reason:)
        @lock.synchronize { @restarts[reason.to_s] += 1 }
      end

      def render(workers: [])
        rows = workers.map { |worker| worker.is_a?(Hash) ? worker : worker.stats.merge(pid: worker.pid, index: worker.index, state: worker.state) }
        @lock.synchronize do
          output = +""
          histogram(output, "rpc_server_duration_seconds", Recorder::DURATION_BUCKETS, :duration_buckets, :duration_sum)
          histogram(output, "rpc_server_requests_per_rpc", Recorder::MESSAGE_BUCKETS, :request_buckets, :request_sum)
          histogram(output, "rpc_server_responses_per_rpc", Recorder::MESSAGE_BUCKETS, :response_buckets, :response_sum)
          output << "# TYPE gritz_rejected_total counter\ngritz_rejected_total #{@rejected}\n"
          output << "# TYPE gritz_worker_restarts_total counter\n"
          @restarts.sort.each { |reason, count| output << "gritz_worker_restarts_total{reason=\"#{escape(reason)}\"} #{count}\n" }
          output << "# TYPE gritz_workers gauge\n"
          Supervisor::WorkerHandle::STATES.each { |state| output << "gritz_workers{state=\"#{state}\"} #{rows.count { |row| row[:state] == state }}\n" }
          serving = rows.select { |row| %w[ready draining].include?(row[:state]) }
          output << "# TYPE gritz_threadpool_busy gauge\ngritz_threadpool_busy #{serving.sum { |row| row[:busy_threads] || row[:busy] || 0 }}\n"
          output << "# TYPE gritz_threadpool_capacity gauge\ngritz_threadpool_capacity #{serving.sum { |row| row[:capacity] || 0 }}\n"
          output << "# TYPE gritz_worker_pss_bytes gauge\n"
          rows.each do |row|
            next unless row[:pss_bytes]

            output << "gritz_worker_pss_bytes{worker=\"#{row[:index]}\",pid=\"#{row[:pid]}\"} #{row[:pss_bytes]}\n"
          end
          output
        end
      end

      private

      def validate_delta!(delta)
        valid = delta.is_a?(Hash) && delta[:rpc].is_a?(Array) && nonnegative_integer?(delta[:rejected])
        raise ConfigurationError, "Invalid metric delta" unless valid

        delta[:rpc].each do |row|
          valid = row.is_a?(Hash) && %i[service method].all? { |key| row[key].is_a?(String) && !row[key].empty? } &&
                  row[:code].is_a?(Integer) && row[:code].between?(0, 16) &&
                  %i[count request_sum response_sum].all? { |key| nonnegative_integer?(row[key]) } &&
                  row[:duration_sum].is_a?(Numeric) && row[:duration_sum].real? && row[:duration_sum].to_f.finite? && row[:duration_sum] >= 0
          raise ConfigurationError, "Invalid RPC metric row" unless valid

          Recorder::BUCKET_FIELDS.each do |field|
            size = field == :duration_buckets ? Recorder::DURATION_BUCKETS.size : Recorder::MESSAGE_BUCKETS.size
            buckets = row[field]
            unless buckets.is_a?(Array) && buckets.size == size && buckets.all? { |count| nonnegative_integer?(count) } && buckets.sum == row[:count]
              raise ConfigurationError, "Invalid RPC metric histogram"
            end
          end
        end
      end

      def nonnegative_integer?(value) = value.is_a?(Integer) && value >= 0

      def histogram(output, name, bounds, bucket_field, sum_field)
        output << "# TYPE #{name} histogram\n"
        @rpc.sort_by { |key, _row| key }.each do |_key, row|
          labels = "rpc_service=\"#{escape(row[:service])}\",rpc_method=\"#{escape(row[:method])}\",rpc_grpc_status_code=\"#{row[:code]}\""
          total = 0
          bounds.each_with_index do |upper, index|
            total += row[bucket_field][index]
            output << "#{name}_bucket{#{labels},le=\"#{upper.infinite? ? '+Inf' : upper}\"} #{total}\n"
          end
          output << "#{name}_sum{#{labels}} #{row[sum_field]}\n#{name}_count{#{labels}} #{row[:count]}\n"
        end
      end

      def escape(value) = value.gsub(/[\\"\n]/) { |character| { "\\" => "\\\\", '"' => '\\"', "\n" => "\\n" }.fetch(character) }
    end
  end
end
