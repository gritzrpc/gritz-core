# frozen_string_literal: true

require "json"

module Gritz
  # Defines fork-safe singleton clients without constructing a native transport.
  # @api public
  class Client
    class << self
      attr_accessor :adapter

      def middleware = @middleware ||= Middleware::Stack.new

      def middleware=(stack)
        raise ArgumentError, "middleware must be a Gritz::Middleware::Stack" unless stack.is_a?(Middleware::Stack)

        @middleware = stack
      end

      def define(stub_class, target:, credentials: :insecure, channel_args: {}, deadline: nil,
                 safety_margin: 0.01, service_config: nil, middleware: nil, adapter: nil)
        unless stub_class.is_a?(Class) && !stub_class.public_instance_methods(false).empty?
          raise ArgumentError, "stub_class must define RPC methods"
        end
        raise ArgumentError, "target must be a nonempty String" unless target.is_a?(String) && !target.strip.empty? && !target.include?("\0")
        raise ArgumentError, "channel_args must be a Hash" unless channel_args.is_a?(Hash)

        validate_time!(:deadline, deadline) unless deadline.nil?
        validate_time!(:safety_margin, safety_margin)
        if middleware && !middleware.is_a?(Middleware::Stack)
          raise ArgumentError, "middleware must be a Gritz::Middleware::Stack"
        end

        args = channel_args.dup
        unless service_config.nil?
          raise ArgumentError, "service_config must be a JSON object" unless service_config.is_a?(Hash)

          args["grpc.service_config"] = JSON.generate(service_config)
          validate_json!(service_config)
        end
        definition = Definition.new(stub_class:, target: target.dup.freeze, credentials:,
                                    args: ChannelRegistry.snapshot(args), deadline:, safety_margin:, middleware:, adapter:)
        Module.new do
          stub_class.public_instance_methods(false).each do |method|
            define_singleton_method(method) do |request, options = {}, **keywords, &block|
              raise ArgumentError, "RPC options must be a Hash" unless options.is_a?(Hash)

              definition.call(method, request, options.merge(keywords), &block)
            end
          end
        end
      rescue JSON::GeneratorError, JSON::NestingError => e
        raise ArgumentError, "invalid service_config: #{e.message}"
      end

      private

      def validate_time!(name, value)
        unless value.is_a?(Numeric) && value.real? && value.finite? && (name == :deadline ? value.positive? : value >= 0)
          raise ArgumentError, "#{name} must be a finite #{name == :deadline ? 'positive' : 'nonnegative'} number"
        end
      end

      def validate_json!(value)
        case value
        when Hash
          value.each do |key, entry|
            raise ArgumentError, "service_config object keys must be Strings or Symbols" unless key.is_a?(String) || key.is_a?(Symbol)

            validate_json!(entry)
          end
        when Array then value.each { |entry| validate_json!(entry) }
        when Float
          raise ArgumentError, "service_config numbers must be finite" unless value.finite?
        when String, Integer, Symbol, TrueClass, FalseClass, NilClass then nil
        else raise ArgumentError, "service_config must contain only JSON values"
        end
      end
    end

    # @api private
    class Definition
      def initialize(stub_class:, target:, credentials:, args:, deadline:, safety_margin:, middleware:, adapter:)
        @stub_class = stub_class
        @target = target
        @credentials = credentials
        @args = args
        @deadline = deadline
        @safety_margin = safety_margin
        @middleware = middleware
        @adapter = adapter
      end

      def call(method, request, options, &)
        ForkGuard.check!(@stub_class)
        invocation = Invocation.new(deadline: @deadline, safety_margin: @safety_margin, options:,
                                    parent: Context.current, middleware: @middleware)
        adapter = @adapter || Client.adapter
        raise ArgumentError, "require gritz/native or provide a client adapter" unless adapter

        connection = ChannelRegistry.fetch(target: @target, credentials: @credentials, args: @args, pool: adapter) do
          adapter.connect(target: @target, credentials: @credentials, args: @args)
        end
        adapter.invoke(stub_class: @stub_class, connection:, method:, request:, options: invocation.options,
                       around: invocation.method(:call), &)
      end
    end
  end
end
