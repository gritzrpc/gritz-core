# frozen_string_literal: true

require "ripper"

module Gritz
  module Compat
    module Gruf
      # Converts a deliberately small, literal-only subset of Gruf.configure.
      class ConfigConverter
        ARGUMENTS = {
          "grpc.max_receive_message_length" => [:max_receive_message_size, 1],
          "grpc.max_send_message_length" => [:max_send_message_size, 1],
          "grpc.max_metadata_size" => [:max_metadata_size, 1],
          "grpc.max_connection_age_ms" => [:max_connection_age, 1000.0],
          "grpc.max_connection_age_grace_ms" => [:max_connection_age_grace, 1000.0],
          "grpc.keepalive_time_ms" => [:keepalive_time, 1000.0]
        }.freeze

        def convert(source)
          settings = assignments(source)
          output = { workers: 0 }
          settings.each do |name, value|
            case name
            when "server_binding_url" then output[:bind] = value
            when "rpc_server_options" then server_options(value, output)
            when "use_ssl", "ssl_crt_file", "ssl_key_file" then next
            when "default_client_host", "default_channel_credentials"
              unsupported("#{name}: configure Gritz::Client.define manually")
            else unsupported("#{name}: manual migration required; see migrating-from-gruf.md")
            end
          end
          config = Gritz::Configuration.new
          output.each { |name, value| config.public_send("#{name}=", value) }
          config.validate!
          tls = tls_options(settings)
          output[:tls] = tls unless tls.empty?
          ["# Review controller registration, interceptors and fork safety before starting.",
           'require "gritz/compat/gruf"', "", *output.map { |name, value| "#{name}(#{value.inspect})" }, "",
           "# register_controller YourMigratedController", ""].join("\n")
        end

        private

        def assignments(source)
          tree = Ripper.sexp(source)
          unsupported("invalid Ruby syntax; manual correction required") unless tree
          statements = tree[1].reject { |node| node[0] == :void_stmt }
          unsupported("expected one Gruf.configure block; other executable code needs manual migration") unless statements.size == 1
          node = statements.first
          call = node[1]
          block = node[2]
          unless node[0] == :method_add_block && call&.dig(0) == :call && call.dig(3, 1) == "configure" &&
                 %i[var_ref top_const_ref].include?(call.dig(1, 0)) && call.dig(1, 1, 1) == "Gruf"
            unsupported("expected Gruf.configure; manual migration required")
          end
          params = block&.dig(1, 1)
          unless %i[do_block brace_block].include?(block&.dig(0)) && params&.dig(0) == :params &&
                 params[1]&.size == 1 && params[2..].all?(&:nil?) && block.dig(1, 2) == false
            unsupported("configure needs one block variable; manual migration required")
          end
          variable = params[1][0][1]
          body = block[2]
          if block[0] == :do_block
            unsupported("rescue/ensure needs manual migration") unless body[2..].all?(&:nil?)
            body = body[1]
          end
          body.each_with_object({}) do |statement, values|
            next if statement[0] == :void_stmt

            field = statement[1]
            unless statement[0] == :assign && field&.dig(0) == :field && field.dig(1, 0) == :var_ref && field.dig(1, 1, 1) == variable
              unsupported("only literal assignments are supported; interceptors and other code require manual migration")
            end
            name = field[3][1]
            unsupported("duplicate setting #{name}; manual migration required") if values.key?(name)
            values[name] = literal(statement[2])
          end
        end

        def literal(node)
          case node[0]
          when :@int then Integer(node[1].delete("_"), 0)
          when :@float then Float(node[1].delete("_"))
          when :string_literal
            parts = node[1][1..]
            unsupported("strings must be literals without interpolation or escapes") unless parts.all? { |part|
              part[0] == :@tstring_content && !part[1].include?("\\")
            }
            parts.map { |part| part[1] }.join
          when :symbol_literal
            token = node.dig(1, 1)
            unsupported("symbol must be a static literal") unless %i[@ident @op @const].include?(token&.dig(0))
            token[1].to_sym
          when :@label then node[1].delete_suffix(":").to_sym
          when :var_ref
            return { "true" => true, "false" => false, "nil" => nil }.fetch(node[1][1]) if node[1][0] == :@kw

            unsupported("dynamic values need manual migration; use static literals")
          when :unary
            unsupported("only negative numeric literals are supported") unless node[1] == :-@ && %i[@int @float].include?(node.dig(2, 0))
            -literal(node[2])
          when :hash
            pairs = node.dig(1, 1) || []
            pairs.each_with_object({}) do |pair, values|
              unsupported("hash splats need manual migration; use literal entries") unless pair[0] == :assoc_new
              key = literal(pair[1])
              unsupported("duplicate hash key #{key}; manual migration required") if values.key?(key)
              values[key] = literal(pair[2])
            end
          else unsupported("dynamic values need manual migration; only static literals are supported")
          end
        rescue ArgumentError, KeyError
          unsupported("invalid literal; manual migration required")
        end

        def server_options(options, output)
          unsupported("rpc_server_options must be a literal Hash") unless options.is_a?(Hash)
          options.each do |name, value|
            case name
            when :pool_size then output[:threads] = value
            when :max_waiting_requests then output[:max_waiting_requests] = value
            when :server_args
              unsupported("server_args must be a literal Hash") unless value.is_a?(Hash)
              value.each do |key, argument|
                conversion = ARGUMENTS[key]
                unsupported("#{key}: manual C-core argument migration required") unless conversion
                unsupported("#{key} must be a numeric literal") unless argument.is_a?(Numeric)
                setting, divisor = conversion
                output[setting] = argument / divisor
              end
            else unsupported("#{name}: manual rpc_server_options migration required")
            end
          end
        end

        def tls_options(settings)
          enabled = settings.fetch("use_ssl", false)
          unsupported("use_ssl must be a boolean literal") unless [true, false].include?(enabled)
          paths = %w[ssl_crt_file ssl_key_file]
          unless enabled
            paths.each { |key| unsupported("#{key} requires use_ssl=true; manual review required") if settings.key?(key) }
            return {}
          end
          unless paths.all? { |key| settings[key].is_a?(String) && !settings[key].empty? }
            unsupported("use_ssl=true requires ssl_crt_file and ssl_key_file; manual review required")
          end
          { cert: settings.fetch("ssl_crt_file"), key: settings.fetch("ssl_key_file") }
        end

        def unsupported(message) = raise Gritz::ConfigurationError, message
      end
    end
  end
end
