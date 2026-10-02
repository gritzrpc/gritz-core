# frozen_string_literal: true

module Gritz
  module Testing
    # Runs all RPC shapes without sockets or grpc initialization.
    # @api public
    class InMemoryCall
      include Gritz::Call

      attr_reader :method_descriptor, :metadata, :deadline, :peer, :peer_identity,
                  :responses, :initial_metadata, :trailing_metadata

      def initialize(method_descriptor:, messages:, metadata: {}, deadline: nil, peer: nil, peer_identity: nil)
        @method_descriptor = method_descriptor
        @messages = messages.to_enum
        @metadata = metadata
        @deadline = deadline
        @peer = peer
        @peer_identity = peer_identity
        @responses = []
        @initial_metadata = {}
        @trailing_metadata = {}
        @cancelled = false
      end

      def read
        @messages.next
      rescue StopIteration
        nil
      end

      def write(message) = @responses << message
      def send_initial_metadata(metadata = {}) = @initial_metadata.merge!(metadata)
      alias merge_initial_metadata send_initial_metadata
      def cancelled? = @cancelled
      def cancel! = @cancelled = true
    end
  end
end
