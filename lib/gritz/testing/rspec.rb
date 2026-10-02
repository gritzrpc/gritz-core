# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"
require_relative "../core"

module Gritz
  module Testing
    # Requiring gritz/testing/rspec enables type: :rpc controller tests.
    # @api public
    module Rspec
      def self.install
        ::RSpec.configure { |config| config.include RpcHelper, type: :rpc }
        ::RSpec::Matchers.define :raise_rpc_error do |code|
          supports_block_expectations

          match do |block|
            @error = nil
            begin
              block.call
              false
            rescue Gritz::Error => e
              @error = e
              e.code == code.to_sym
            end
          end

          failure_message do
            "expected RPC error #{code}, got #{@error ? @error.code : 'no error'}"
          end

          failure_message_when_negated do
            "expected no RPC error #{code}, got #{@error.code}"
          end
        end
      end
    end
  end
end

Gritz::Testing::Rspec.install
