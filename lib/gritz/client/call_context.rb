# frozen_string_literal: true

require "logger"

module Gritz
  class Client
    # Middleware state for an outgoing RPC, independent of its transport.
    # @api public
    class CallContext
      attr_reader :method, :kind, :options, :parent, :store, :logger
      attr_accessor :request, :operation, :trace_context, :response_block

      def initialize(method:, kind:, request:, options:, parent:, terminal:)
        service, name = method.delete_prefix("/").split("/", 2)
        @method = MethodDescriptor.new(service:, name:, input_type: nil, output_type: nil,
                                       client_streaming: %i[client_streaming bidi].include?(kind),
                                       server_streaming: %i[server_streaming bidi].include?(kind))
        @kind = kind
        @request = request
        @options = options
        @parent = parent
        @terminal = terminal
        @store = {}
        @logger = parent&.logger || Logger.new($stderr)
        @trace_context = parent&.trace_context
      end

      def metadata = options[:metadata]
      def deadline = options[:deadline]
      def remaining = deadline && [deadline - Time.now, 0.0].max
      def request_id = metadata["x-request-id"]
      def cancelled? = !!(store[:gritz_cancelled] || parent&.cancelled? || operation&.cancelled?)

      def check_deadline!
        raise Errors::DeadlineExceeded, "deadline exceeded" if deadline && remaining.zero?
      end

      def check_cancelled!
        raise Errors::Cancelled, "request cancelled" if cancelled?
      end

      # Input streams stay lazy and retain the parent even on native writer threads.
      # @api private
      def each_request
        Enumerator.new do |output|
          Context.with(parent) do
            request.each do |message|
              check_deadline!
              check_cancelled!
              output << message
            end
          end
        end
      end

      # @api private
      def execute = @terminal.call(self, &response_block)
    end
  end
end
