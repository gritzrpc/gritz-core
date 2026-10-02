# frozen_string_literal: true

module Gritz
  # Contract implemented by transports and in-memory RPC calls.
  # @api public
  module Call
    def method_descriptor = raise NotImplementedError
    def metadata = raise NotImplementedError
    def deadline = nil
    def peer = nil
    def peer_identity = nil
    def cancelled? = false
    def read = raise NotImplementedError
    def write(message) = raise NotImplementedError
    def send_initial_metadata(metadata = {}) = raise NotImplementedError
    def merge_initial_metadata(metadata = {}) = send_initial_metadata(metadata)
    def trailing_metadata = raise NotImplementedError

    def each_message
      return enum_for(__method__) unless block_given?

      while (message = read)
        yield message
      end
    end
  end
end
