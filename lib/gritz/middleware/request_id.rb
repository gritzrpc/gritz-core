# frozen_string_literal: true

require "securerandom"

module Gritz
  module Middleware
    # Assigns and echoes a correlation ID for each RPC.
    # @api public
    class RequestId
      def initialize(app)
        @app = app
      end

      def call(context)
        incoming = Array(context.metadata["x-request-id"]).first
        context.request_id = incoming.is_a?(String) && incoming.match?(/\A[\x21-\x7e]{1,128}\z/) ? incoming : SecureRandom.uuid
        metadata = { "x-request-id" => context.request_id }
        if context.call.respond_to?(:merge_initial_metadata)
          context.call.merge_initial_metadata(metadata)
        else
          context.call.send_initial_metadata(metadata)
        end
        @app.call(context)
      end
    end
  end
end
