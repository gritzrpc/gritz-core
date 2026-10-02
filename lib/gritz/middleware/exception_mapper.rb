# frozen_string_literal: true

require "securerandom"
require "json"

module Gritz
  module Middleware
    # Converts application exceptions to safe RPC errors.
    # @api public
    class ExceptionMapper
      def initialize(app, mappings: {}, expose_errors: false)
        @app = app
        @mappings = mappings
        @expose_errors = expose_errors
      end

      def call(context)
        @app.call(context)
      rescue Gritz::Error
        raise
      rescue StandardError => e
        mapping = @mappings.find { |klass, _| e.is_a?(klass) }&.last
        if mapping
          raise(mapping.respond_to?(:call) ? mapping.call(e) : Errors.for_code(mapping).new(e.message))
        end

        case e.class.name
        when "ActiveRecord::RecordNotFound"
          raise Errors::NotFound, "record not found"
        when "ActiveRecord::RecordInvalid"
          raise Errors::InvalidArgument, "invalid record"
        end

        error_id = SecureRandom.uuid
        context.logger.error(JSON.generate(error_id:, request_id: context.request_id, error: e.class.name,
                                           message: e.message, backtrace: e.backtrace))
        raise Errors::Internal.new(@expose_errors ? e.message : "internal error (#{error_id})", metadata: { "error-id" => error_id })
      end
    end
  end
end
