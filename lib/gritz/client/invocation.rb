# frozen_string_literal: true

require "securerandom"

module Gritz
  class Client
    # Captures the deadline, parent context, and middleware for one outgoing RPC.
    # @api private
    class Invocation
      attr_reader :options

      def initialize(deadline: nil, safety_margin: 0.01, options: {}, parent: nil, middleware: nil)
        validate_duration!(deadline, :deadline, positive: true) unless deadline.nil?
        validate_duration!(safety_margin, :safety_margin, positive: false)
        raise ArgumentError, "return_op is not supported by Gritz::Client" if options[:return_op]

        @parent = parent
        @options = options.dup
        explicit = options[:deadline]
        raise ArgumentError, "deadline must be an absolute Time" unless explicit.nil? || explicit.is_a?(Time)

        now = Time.now
        candidates = [explicit, deadline && (now + deadline), parent&.deadline && (parent.deadline - safety_margin)].compact
        @options[:deadline] = candidates.min
        @options[:metadata] = prepare_metadata(options.fetch(:metadata, {}))
        check_parent!
        raise Errors::DeadlineExceeded, "deadline exceeded" if @options[:deadline] && @options[:deadline] <= now

        stack = Client.middleware.dup
        stack.entries.concat(middleware.entries) if middleware
        @app = stack.build(lambda(&:execute))
      end

      def call(terminal, method:, kind:, request:, options:, &block)
        context = CallContext.new(method:, kind:, request:, options:, parent: @parent, terminal:)
        if context.method.server_streaming? && !block
          Enumerator.new { |output| run(context) { |reply| output << reply } }
        else
          run(context, &block)
        end
      end

      private

      def run(context, &block)
        Context.with(@parent) do
          context.check_deadline!
          context.check_cancelled!
          context.response_block = block
          @app.call(context)
        end
      end

      def check_parent!
        raise Errors::Cancelled, "request cancelled" if @parent&.cancelled?
      end

      def prepare_metadata(metadata)
        raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)

        copied = metadata.to_h { |key, value| [key.to_s, copy_metadata_value(value)] }
        copied["x-request-id"] ||= copy_metadata_value(@parent&.request_id) || SecureRandom.uuid
        %w[traceparent tracestate].each do |key|
          value = @parent&.metadata&.[](key)
          copied[key] ||= copy_metadata_value(value) if value
        end
        copied
      end

      def copy_metadata_value(value)
        case value
        when Array then value.map { |item| item.is_a?(String) ? item.dup : item }
        when String then value.dup
        else value
        end
      end

      def validate_duration!(value, name, positive:)
        valid = value.is_a?(Numeric) && value.real? && value.finite? && (positive ? value.positive? : value >= 0)
        raise ArgumentError, "#{name} must be a finite #{positive ? 'positive' : 'nonnegative'} number" unless valid
      end
    end
  end
end
