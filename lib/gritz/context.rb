# frozen_string_literal: true

module Gritz
  # Request state inherited by child fibers and threads using Ruby Fiber storage.
  # @api public
  class Context
    attr_reader :call, :logger, :store
    attr_accessor :request_id, :trace_context

    def initialize(call:, logger:)
      @call = call
      @logger = logger
      @store = {}
    end

    def self.current = Fiber[:gritz_context]

    def self.with(context)
      previous = current
      Fiber[:gritz_context] = context
      yield
    ensure
      Fiber[:gritz_context] = previous
    end

    def metadata = call.metadata
    def deadline = call.deadline
    def method = call.method_descriptor
    def peer = call.peer
    def peer_identity = call.peer_identity
    def cancelled? = call.cancelled?
    def remaining = deadline && [deadline - Time.now, 0.0].max

    def check_deadline!
      raise Errors::DeadlineExceeded, "deadline exceeded" if deadline && remaining.zero?
    end

    def check_cancelled!
      raise Errors::Cancelled, "request cancelled" if cancelled?
    end

    # Keep serialization failures within the request's exception mapper.
    # @api private
    def validate_response!(message)
      raise TypeError, "RPC response must be #{method.output_type}, got #{message.class}" unless message.is_a?(method.output_type)

      message
    end
  end
end
