# frozen_string_literal: true

require "socket"
require "json"

module Gritz
  module Supervisor
    # Small, bounded HTTP probe listener polled by its owning process.
    # @api private
    class AdminServer
      MAX_CLIENTS = 32
      MAX_HEADER_BYTES = 8192
      CLIENT_TIMEOUT = 2.0
      attr_reader :io, :address

      def initialize(bind:, status:, ready:, metrics:, logger:)
        host, port = bind.match(/\A(\[[^\]]+\]|[^:]+):(\d+)\z/).captures
        host = host.delete_prefix("[").delete_suffix("]")
        @io = TCPServer.new(host, Integer(port))
        @address = "#{host.include?(':') ? "[#{host}]" : host}:#{@io.addr[1]}"
        @status = status
        @ready = ready
        @metrics = metrics
        @logger = logger
        @clients = {}
        @read_buffer = +""
      end

      def ios = [@io, *@clients.keys]

      def poll
        4.times do
          socket = @io.accept_nonblock(exception: false)
          break if socket == :wait_readable

          if @clients.size >= MAX_CLIENTS
            socket.close
          else
            @clients[socket] = { input: +"".b, output: nil, deadline: monotonic + CLIENT_TIMEOUT }
          end
        rescue Errno::ECONNABORTED
          next
        end
        @clients.each do |socket, client|
          if monotonic >= client[:deadline]
            drop(socket)
            next
          end
          read_request(socket, client) unless client[:output]
          write_response(socket, client) if client[:output]
        rescue IOError, SystemCallError
          drop(socket)
        end
      end

      def close
        @clients.each_key(&:close)
        @clients.clear
        @io.close unless @io.closed?
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def drop(socket)
        @clients.delete(socket)
        socket.close unless socket.closed?
      end

      def read_request(socket, client)
        chunk = socket.read_nonblock(4096, @read_buffer, exception: false)
        return if chunk == :wait_readable
        return drop(socket) if chunk.nil?

        client[:input] << chunk
        if client[:input].bytesize > MAX_HEADER_BYTES
          respond(client, 431, "Request headers too large\n")
        elsif client[:input].include?("\r\n\r\n")
          method, path, version = client[:input].lines.first.split
          if !%w[HTTP/1.0 HTTP/1.1].include?(version)
            respond(client, 400, "Invalid request\n")
          elsif method != "GET"
            respond(client, 405, "GET required\n")
          else
            route(client, path)
          end
        end
      end

      def route(client, path)
        case path
        when "/livez" then respond(client, 200, "ok\n")
        when "/readyz"
          ready = @ready.call
          respond(client, ready ? 200 : 503, ready ? "ready\n" : "not ready\n")
        when "/status" then respond(client, 200, "#{JSON.generate(@status.call)}\n", "application/json")
        when "/metrics" then respond(client, 200, @metrics.call, "text/plain; version=0.0.4")
        else respond(client, 404, "Not found\n")
        end
      rescue StandardError => e
        @logger.error("Admin #{path}: #{e.message}")
        respond(client, 500, "Internal error\n")
      end

      def respond(client, code, body, content_type = "text/plain")
        reasons = { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 405 => "Method Not Allowed",
                    431 => "Request Header Fields Too Large", 500 => "Internal Server Error", 503 => "Service Unavailable" }
        client[:output] =
          "HTTP/1.1 #{code} #{reasons.fetch(code)}\r\nContent-Type: #{content_type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      end

      def write_response(socket, client)
        written = socket.write_nonblock(client[:output], exception: false)
        return if written == :wait_writable

        client[:output] = client[:output].byteslice(written..)
        drop(socket) if client[:output].empty?
      end
    end
  end
end
