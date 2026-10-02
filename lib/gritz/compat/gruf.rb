# frozen_string_literal: true

require "gritz/core"
require "json"

module Gritz
  module Compat
    # Selected Gruf 2.22 controller/interceptor APIs, without loading Gruf or grpc.
    # @api public
    module Gruf
      REQUEST_KEY = Object.new.freeze

      # @api private
      def self.request_for(context)
        context.store[REQUEST_KEY] ||= Request.new(context)
      end

      # Wraps a Gruf-style interceptor as a Gritz server middleware.
      # @param klass [Class] interceptor implementing #call and yielding to the action
      # @return [Class] middleware accepted by Middleware::Stack#use
      # @api public
      def self.interceptor(klass)
        Class.new(InterceptorAdapter) do
          define_method(:initialize) { |app, **options| super(app, klass, options) }
        end
      end

      class RequestContext < Hash
        def [](key) = super(convert_key(key))

        def []=(key, value)
          super(convert_key(key), value)
        end

        def fetch(key, ...) = super(convert_key(key), ...)
        def key?(key) = super(convert_key(key))
        def merge!(other, &) = super(other.transform_keys { |key| convert_key(key) }, &)
        alias update merge!

        private

        def convert_key(key) = key.is_a?(Symbol) ? key.to_s : key
      end

      class ActiveCall
        def initialize(context) = @context = context
        def metadata = @context.metadata
        def deadline = @context.deadline
        def peer = @context.peer
        def cancelled? = @context.cancelled?
        def output_metadata = @context.call.trailing_metadata
      end

      class Request
        attr_reader :context, :active_call, :error

        def initialize(context)
          @rpc_context = context
          @original = Gritz::Controller::Request.for(context)
          @context = RequestContext.new
          @active_call = ActiveCall.new(context)
          @error = Error.new
        end

        def service = @rpc_context.method.service_class
        def method_key = @rpc_context.method.action
        def request_class = @rpc_context.method.input_type
        def response_class = @rpc_context.method.output_type
        def metadata = @rpc_context.metadata
        def type = self
        def client_streamer? = @rpc_context.method.kind == :client_streaming
        def server_streamer? = @rpc_context.method.kind == :server_streaming
        def bidi_streamer? = @rpc_context.method.kind == :bidi
        def request_response? = @rpc_context.method.kind == :unary

        def service_key
          name = service.name || @rpc_context.method.service
          name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .gsub("::", ".").downcase.delete_suffix(".service")
        end

        def method_name = "#{service_key}.#{method_key}"

        def message
          return @original.message unless @rpc_context.method.client_streaming?

          @message ||= client_streamer? ? proc { |&block| @original.each_message(&block) } : @original.each_message
        end

        def messages(&block)
          return [message] unless @rpc_context.method.client_streaming?

          block ? @original.each_message(&block) : @original.each_message
        end
      end

      class Error
        Field = Struct.new(:field_name, :error_code, :message)
        DebugInfo = Struct.new(:detail, :stack_trace)
        attr_accessor :code, :app_code, :message
        attr_reader :field_errors, :debug_info, :metadata

        def initialize
          @field_errors = []
          @metadata = {}
        end

        def add_field_error(field, code, message = "") = @field_errors << Field.new(field, code, message)
        def has_field_errors? = !@field_errors.empty? # rubocop:disable Naming/PredicatePrefix -- Preserve the upstream Gruf method name.

        def set_debug_info(detail, stack_trace = [])
          @debug_info = DebugInfo.new(detail, stack_trace.is_a?(String) ? stack_trace.split("\n") : Array(stack_trace))
        end

        def metadata=(value)
          @metadata = value.transform_values(&:to_s)
        end

        def to_h
          { code:, app_code:, message:, field_errors: field_errors.map(&:to_h), debug_info: debug_info.to_h }
        end

        def fail!(_active_call = nil)
          canonical = { bad_request: :invalid_argument, unauthorized: :permission_denied }.fetch(code, code)
          trailers = metadata.merge("error-internal-bin" => JSON.generate(to_h))
          raise Gritz::Errors.for_code(canonical).new(message, metadata: trailers)
        end
      end

      module ErrorHelpers
        def add_field_error(...) = error.add_field_error(...)
        def has_field_errors? = error.has_field_errors? # rubocop:disable Naming/PredicatePrefix -- Preserve the upstream Gruf method name.
        def set_debug_info(...) = error.set_debug_info(...)

        def fail!(code, app_code = nil, message = "", metadata = {})
          error.code = code.to_sym
          error.app_code = app_code ? app_code.to_sym : error.code
          error.message = message.to_s
          error.metadata = metadata
          error.fail!(request.active_call)
        end
      end

      # Controller base retaining selected Gruf request, error and streaming APIs.
      # @api public
      class Controller < Gritz::Controller
        include ErrorHelpers

        def self.bound_service = service_class

        def self.action_defined?(action)
          super && ![Controller, ErrorHelpers].include?(instance_method(action).owner)
        end

        def initialize(context:)
          super
          @request = Gruf.request_for(context)
        end

        def error = request.error

        def process(action)
          result = super
          return result unless context.method.server_streaming?

          result.each { |message| stream.write(message) } if result.respond_to?(:each)
          nil
        end
      end

      Base = Controller

      # Base for migrated interceptors whose #call yields to the next handler.
      # @api public
      class ServerInterceptor
        include ErrorHelpers

        attr_reader :request, :error, :options

        def initialize(request, error, options = {})
          @request = request
          @error = error
          @options = options
        end
      end

      class InterceptorAdapter
        def initialize(app, klass, options)
          @app = app
          @klass = klass
          @options = options
        end

        def call(context)
          request = Gruf.request_for(context)
          @klass.new(request, request.error, @options.dup).call { @app.call(context) }
        end
      end
    end
  end
end
