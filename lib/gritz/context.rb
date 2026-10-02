# frozen_string_literal: true

module Gritz
  # Request state inherited by child fibers and threads using Ruby Fiber storage.
  # @api public
  class Context
    attr_reader :call, :logger, :store, :metrics, :worker, :log_format, :log_redact,
                :requests_count, :responses_count, :bytes_in, :bytes_out
    attr_accessor :request_id, :trace_context

    def initialize(call:, logger:, metrics: nil, worker: nil, log_format: :json, log_redact: [])
      @call = call
      @logger = logger
      @store = {}
      @metrics = metrics
      @worker = worker
      @log_format = log_format
      @log_redact = log_redact.map(&:to_s)
      @requests_count = @responses_count = @bytes_in = @bytes_out = 0
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

    # @api private
    def record_received(message)
      return unless message

      size = encoded_size(message)
      @requests_count += 1
      @bytes_in += size
    end

    # @api private
    def record_sent(message)
      size = encoded_size(message)
      @responses_count += 1
      @bytes_out += size
    end

    private

    def encoded_size(message)
      # ponytail: byte accounting encodes again; instrument native serialization if the Phase 6 overhead budget is exceeded.
      message.class.respond_to?(:encode) ? message.class.encode(message).bytesize : message.to_s.bytesize
    end
  end
end
