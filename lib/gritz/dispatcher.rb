# frozen_string_literal: true

require "logger"

module Gritz
  # Routes one Call through the configured middleware and a fresh controller.
  # @api public
  class Dispatcher
    attr_reader :router

    def initialize(router:, middleware: Middleware::Stack.default, logger: Logger.new($stdout))
      @router = router
      @logger = logger
      endpoint = lambda do |context|
        context.check_deadline!
        context.check_cancelled!
        descriptor = router.resolve(context.method.full_name)
        result = descriptor.controller.new(context:).process(descriptor.action)
        context.check_deadline!
        context.check_cancelled!
        descriptor.server_streaming? ? result : context.validate_response!(result)
      end
      @app = middleware ? middleware.build(endpoint) : endpoint
    end

    def call(call)
      @app.call(Context.new(call:, logger: @logger))
    end
  end
end
