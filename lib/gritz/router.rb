# frozen_string_literal: true

module Gritz
  # Resolves generated service descriptors to controller actions at boot.
  # @api public
  class Router
    attr_reader :routes

    def initialize(controllers:, strict: false, logger: nil)
      @routes = {}
      services = {}
      missing = []
      controllers.each do |controller|
        service = controller.service_class
        raise ArgumentError, "#{controller} has no bound service" unless service
        raise ArgumentError, "service #{service.service_name} is already bound" if services.key?(service.service_name)

        services[service.service_name] = controller
        service.rpc_descs.each do |name, rpc|
          input_stream = rpc.client_streamer? || rpc.bidi_streamer?
          output_stream = rpc.server_streamer? || rpc.bidi_streamer?
          route = MethodDescriptor.new(service: service.service_name, name:, input_type: input_stream ? rpc.input.type : rpc.input,
                                       output_type: output_stream ? rpc.output.type : rpc.output, client_streaming: input_stream,
                                       server_streaming: output_stream, controller:, service_class: service)
          @routes[route.full_name] = route
          missing << "#{controller}##{route.action}" unless controller.action_defined?(route.action)
        end
      end
      unless missing.empty?
        message = "unimplemented RPC actions: #{missing.join(', ')}"
        raise ArgumentError, message if strict

        logger&.warn(message)
      end
      @routes.freeze
    end

    def resolve(full_name)
      routes.fetch(full_name) { raise Errors::Unimplemented, "unknown RPC: #{full_name}" }
    end
  end
end
