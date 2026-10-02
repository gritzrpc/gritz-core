# frozen_string_literal: true

require "logger"

module Gritz
  module Testing
    # Controller tests exercise the real dispatcher without opening a socket.
    # @api public
    module RpcHelper
      attr_reader :last_rpc_call

      def rpc(action, messages, controller: nil, metadata: {}, deadline: nil, peer: nil, peer_identity: nil,
              middleware: true, logger: Logger.new(File::NULL))
        controller ||= described_class if respond_to?(:described_class)
        raise ArgumentError, "pass controller: or use an RSpec controller example group" unless controller

        router = Router.new(controllers: [controller], logger:)
        descriptor = router.routes.values.find { |route| route.action == action.to_sym || route.name == action.to_s }
        raise ArgumentError, "unknown RPC action: #{action}" unless descriptor

        input = descriptor.client_streaming? ? messages : [messages]
        @last_rpc_call = InMemoryCall.new(method_descriptor: descriptor, messages: input, metadata:, deadline:, peer:, peer_identity:)
        stack = middleware == true ? Middleware::Stack.default : middleware
        result = Dispatcher.new(router:, middleware: stack, logger:).call(@last_rpc_call)
        descriptor.server_streaming? ? @last_rpc_call.responses : result
      end
    end
  end
end
