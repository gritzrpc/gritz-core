# frozen_string_literal: true

module Gritz
  module Middleware
    # One completion observation wraps the complete unary or streaming action.
    # @api public
    class Metrics
      def initialize(app)
        @app = app
      end

      def call(context)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        code = 0
        @app.call(context)
      rescue Gritz::Error => e
        code = e.grpc_code
        raise
      rescue StandardError
        code = 13
        raise
      ensure
        context.metrics&.record_rpc(service: context.method.service, method: context.method.name, code: code,
                                    duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                                    requests: context.requests_count, responses: context.responses_count)
      end
    end
  end
end
