# frozen_string_literal: true

module Gritz
  module Middleware
    # Sets request-local state for the entire lifetime of an RPC.
    # @api public
    class Context
      def initialize(app)
        @app = app
      end

      def call(context)
        Gritz::Context.with(context) { @app.call(context) }
      end
    end
  end
end
