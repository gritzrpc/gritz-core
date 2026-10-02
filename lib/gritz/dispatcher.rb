# frozen_string_literal: true

require "logger"

module Gritz
  # Routes one Call through the configured middleware and a fresh controller.
  # @api public
  class Dispatcher
    attr_reader :router

    def initialize(router:, middleware: Middleware::Stack.default, logger: Logger.new($stdout),
                   metrics: nil, worker: nil, log_format: :json, log_redact: [])
      @router = router
      @logger = logger
      @context_options = { metrics: metrics, worker: worker, log_format: log_format, log_redact: log_redact }
      endpoint = lambda do |context|
        context.check_deadline!
        context.check_cancelled!
        descriptor = router.resolve(context.method.full_name)
        result = descriptor.controller.new(context:).process(descriptor.action)
        context.check_deadline!
        context.check_cancelled!
        unless descriptor.server_streaming?
          context.validate_response!(result)
          context.record_sent(result)
        end
        result
      end
      @app = middleware ? middleware.build(endpoint) : endpoint
    end

    def call(call)
      @app.call(Context.new(call:, logger: @logger, **@context_options))
    end
  end
end
