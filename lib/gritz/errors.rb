# frozen_string_literal: true

module Gritz
  # Transport-independent status and rich error details.
  # @api public
  class Error < StandardError
    attr_reader :details, :metadata

    def initialize(message = nil, details: [], metadata: {}, remote: false)
      super(message || code.to_s.tr("_", " "))
      @details = details
      @metadata = metadata
      @remote = remote
    end

    def code = self.class::CODE
    def grpc_code = self.class::GRPC_CODE
    def remote? = @remote

    CODE = :unknown
    GRPC_CODE = 2
  end

  # gRPC's canonical codes, without a dependency on the grpc gem.
  # @api public
  module Errors
    CODES = %i[ok cancelled unknown invalid_argument deadline_exceeded not_found already_exists permission_denied
               resource_exhausted failed_precondition aborted out_of_range unimplemented internal unavailable data_loss unauthenticated].freeze

    CODES.each_with_index do |code, number|
      klass = Class.new(Error)
      klass.const_set(:CODE, code)
      klass.const_set(:GRPC_CODE, number)
      const_set(code.to_s.split("_").map(&:capitalize).join, klass)
    end

    def self.for_code(code)
      name = case code
             when Integer then CODES[code] if code >= 0
             when String, Symbol then code.to_sym
             end
      raise ArgumentError, "unknown RPC status: #{code.inspect}" unless CODES.include?(name)

      const_get(name.to_s.split("_").map(&:capitalize).join, false)
    end
  end

  DeadlineExceeded = Errors::DeadlineExceeded
end
