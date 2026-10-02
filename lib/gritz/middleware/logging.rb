# frozen_string_literal: true

require "json"

module Gritz
  module Middleware
    # Logs one structured completion row per RPC, including streaming failures.
    # @api public
    class Logging
      def initialize(app)
        @app = app
      end

      def call(context)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        code = :ok
        @app.call(context)
      rescue Gritz::Error => e
        code = e.code
        raise
      rescue StandardError
        code = :internal
        raise
      ensure
        duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        context.logger.info(JSON.generate(request_id: context.request_id, service: context.method.service,
                                          method: context.method.name, code:, duration_ms: duration.round(3),
                                          peer: context.peer, pid: Process.pid))
      end
    end
  end
end
