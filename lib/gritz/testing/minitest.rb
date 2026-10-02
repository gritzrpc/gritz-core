# frozen_string_literal: true

require_relative "../core"

module Gritz
  module Testing
    # Include in a Minitest test and pass controller: to rpc.
    # @api public
    module Minitest
      include RpcHelper

      def assert_rpc_error(code, message = nil, &)
        error = assert_raises(Gritz::Error, *[message].compact, &)
        assert_equal(code.to_sym, error.code, message)
        error
      end
    end
  end
end
