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
        fields = { request_id: context.request_id, service: context.method.service,
                   method: context.method.name, code: code, duration_ms: duration.round(3),
                   peer: context.peer, worker: context.worker, pid: Process.pid, bytes_in: context.bytes_in, bytes_out: context.bytes_out }
        fields.merge!(context.store.fetch(:gritz_error, {}))
        fields = prepare(fields, context.log_redact)
        message = if context.log_format == :logfmt
                    fields.map do |key, value|
                      value = value.to_s if value.is_a?(Symbol)
                      value = JSON.generate(value) if value.is_a?(Hash) || value.is_a?(Array)
                      "#{key}=#{JSON.generate(value)}"
                    end.join(" ")
                  else
                    JSON.generate(fields)
                  end
        context.logger.info(message)
      end

      private

      def prepare(value, redacted)
        case value
        when Hash
          value.to_h { |key, item| [key, redacted.include?(key.to_s) ? "[FILTERED]" : prepare(item, redacted)] }
        when Array then value.map { |item| prepare(item, redacted) }
        when String then value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        else value
        end
      end
    end
  end
end
