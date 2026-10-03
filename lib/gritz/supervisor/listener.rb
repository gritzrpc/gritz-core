# frozen_string_literal: true

require "socket"

module Gritz
  module Supervisor
    # Creates a plain TCP listener without initializing a transport or scheduler.
    # @api private
    module Listener
      def self.bind(address, reuseport: false)
        host, _, port = address.rpartition(":")
        info = Addrinfo.tcp(host.delete_prefix("[").delete_suffix("]"), Integer(port))
        socket = Socket.new(info.afamily, Socket::SOCK_STREAM)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1) if reuseport
        socket.bind(info)
        socket.listen(Socket::SOMAXCONN)
        socket
      rescue StandardError
        socket&.close
        raise
      end
    end
  end
end
