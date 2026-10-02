# frozen_string_literal: true

module Gritz
  # One instance is created per RPC; application actions use request and stream.
  # @api public
  class Controller
    class << self
      def bind(service)
        raise ArgumentError, "service must expose service_name and rpc_descs" unless service.respond_to?(:service_name) && service.respond_to?(:rpc_descs)

        @service_class = service
      end

      def service_class = @service_class || (superclass.service_class if superclass.respond_to?(:service_class))

      def action_defined?(action)
        public_method_defined?(action) && ancestors.take_while { |ancestor| ancestor != Controller }.include?(instance_method(action).owner)
      end

      %i[before around after].each do |kind|
        define_method("#{kind}_action") do |method = nil, only: nil, except: nil, &block|
          callback = method || block
          raise ArgumentError, "callback required" unless callback

          (@filters ||= []) << [kind, callback, Array(only).map(&:to_sym), Array(except).map(&:to_sym)]
        end
      end

      def filters = (superclass.respond_to?(:filters) ? superclass.filters : []) + (@filters || [])

      def rescue_from(*errors, with: nil, &block)
        handler = with || block
        raise ArgumentError, "handler required" unless handler

        (@rescue_handlers ||= []).concat(errors.map { |error| [error, handler] })
      end

      def rescue_handlers = (superclass.respond_to?(:rescue_handlers) ? superclass.rescue_handlers : []) + (@rescue_handlers || [])
    end

    attr_reader :context, :request, :stream

    def initialize(context:)
      @context = context
      @request = Request.for(context)
      @stream = Stream.new(context.call, context)
    end

    def process(action)
      raise Errors::Unimplemented, "unimplemented RPC action: #{action}" unless self.class.action_defined?(action)

      applicable = self.class.filters.select do |_, _, only, except|
        (only.empty? || only.include?(action)) && !except.include?(action)
      end
      endpoint = lambda do
        applicable.each { |kind, callback, _, _| invoke_callback(callback) if kind == :before }
        result = public_send(action)
        applicable.each { |kind, callback, _, _| invoke_callback(callback) if kind == :after }
        result
      end
      applicable.select { |kind,| kind == :around }.reverse_each do |_, callback, _, _|
        inner = endpoint
        endpoint = lambda do
          called = false
          result = nil
          callback_result = invoke_callback(callback, lambda {
            called = true
            result = inner.call
          })
          called ? result : callback_result
        end
      end
      endpoint.call
    rescue StandardError => e
      handler = self.class.rescue_handlers.reverse.find { |klass, _| e.is_a?(klass) }
      raise unless handler

      invoke_callback(handler.last, e)
    end

    def fail!(code, message = nil, details: [], metadata: {})
      raise Errors.for_code(code).new(message, details:, metadata:)
    end

    private

    def invoke_callback(callback, argument = nil)
      return argument ? instance_exec(argument, &callback) : instance_exec(&callback) if callback.respond_to?(:call)
      return __send__(callback, &argument) if argument.is_a?(Proc)

      argument ? __send__(callback, argument) : __send__(callback)
    end

    # @api public
    class Request
      STORE_KEY = Object.new.freeze

      # @api private
      def self.for(context)
        context.store[STORE_KEY] ||= new(context.call, context)
      end

      def initialize(call, context)
        @call = call
        @context = context
        unless context.method.client_streaming?
          @message = @call.read
          @context.record_received(@message)
        end
      end

      def message
        @context.check_deadline!
        @context.check_cancelled!
        return @message if defined?(@message)

        @message = @call.read
        @context.record_received(@message)
        @message
      end

      def each_message
        return enum_for(__method__) unless block_given?

        unless @context.method.client_streaming?
          value = message
          yield value if value
          return
        end

        @call.each_message do |message|
          @context.check_deadline!
          @context.check_cancelled!
          @context.record_received(message)
          yield message
        end
      end

      alias messages each_message
    end

    # @api public
    class Stream
      def initialize(call, context)
        @call = call
        @context = context
      end

      def write(message)
        raise TypeError, "RPC method does not stream responses" unless @context.method.server_streaming?

        @context.check_deadline!
        @context.check_cancelled!
        @context.validate_response!(message)
        @call.write(message)
        @context.record_sent(message)
      end
    end
  end
end
