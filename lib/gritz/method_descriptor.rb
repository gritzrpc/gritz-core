# frozen_string_literal: true

module Gritz
  # Immutable route and protobuf type information for one RPC.
  # @api public
  class MethodDescriptor
    attr_reader :service, :name, :input_type, :output_type, :controller, :service_class, :action

    def initialize(service:, name:, input_type:, output_type:, client_streaming: false, server_streaming: false,
                   controller: nil, service_class: nil)
      @service = service.to_s
      @name = name.to_s
      @input_type = input_type
      @output_type = output_type
      @client_streaming = client_streaming
      @server_streaming = server_streaming
      @controller = controller
      @service_class = service_class
      @action = @name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
      freeze
    end

    def full_name = "/#{service}/#{name}"
    def client_streaming? = @client_streaming
    def server_streaming? = @server_streaming

    def kind
      return :bidi if client_streaming? && server_streaming?
      return :client_streaming if client_streaming?
      return :server_streaming if server_streaming?

      :unary
    end
  end
end
