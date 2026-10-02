# frozen_string_literal: true

require "json"

module Gritz
  # Validated startup settings for single-process and supervised servers.
  # @api public
  class Configuration
    DEFAULTS = {
      workers: 0, threads: 16, max_waiting_requests: 64,
      transport: :native, listener_strategy: :reuseport,
      bind: "0.0.0.0:50051", admin_bind: "127.0.0.1:9090",
      fork_mode: :clean, fork_guard: :raise, strict_routes: false,
      drain_delay: 5.0, shutdown_timeout: 25.0, worker_boot_timeout: 60.0,
      worker_timeout: 30.0, status_interval: 1.0, min_ready_workers: 1,
      phased_restart_surge: 1, max_connection_age: 300.0,
      max_connection_age_grace: 30.0, keepalive_time: 60.0,
      keepalive_permit_without_calls: true,
      max_receive_message_size: 4 * 1024 * 1024,
      max_send_message_size: 4 * 1024 * 1024, max_metadata_size: 8192,
      metrics_backend: :pipe, log_format: :json, worker_recycle: {}, tls: {}
    }.freeze
    ENUMS = {
      transport: %i[native async], listener_strategy: %i[reuseport inherited_fd port_per_worker],
      fork_mode: %i[clean grpc_fork_support], fork_guard: %i[raise warn off],
      metrics_backend: %i[pipe otlp mmap], log_format: %i[json logfmt]
    }.freeze
    HOOKS = %i[before_fork on_worker_boot on_worker_shutdown].freeze

    attr_accessor(*DEFAULTS.keys, :controllers, :middleware, :preload_app)
    attr_reader :health_checks

    def initialize
      DEFAULTS.each { |name, value| public_send("#{name}=", value.dup) }
      @controllers = []
      @middleware = Middleware::Stack.default
      @hooks = HOOKS.to_h { |name| [name, []] }
      @health_checks = {}
      @preload_app = false
      @preloaders = []
    end

    # CLI overrides > environment > configuration file > defaults.
    def self.load(path: nil, env: ENV, overrides: {})
      config = new
      DSL.new(config).evaluate(path) if path
      env.each do |key, value|
        next unless key.start_with?("GRITZ_")
        next if key == "GRITZ_RELEASE" # Dependency selection in the release workflow, not a runtime setting.

        name = key.delete_prefix("GRITZ_").downcase.to_sym
        raise ConfigurationError, "Unknown environment setting #{key}" unless DEFAULTS.key?(name)
        next if overrides.key?(name)

        config.public_send("#{name}=", parse_environment(name, value))
      end
      overrides.each { |name, value| config.public_send("#{name}=", value) }
      config.validate!
    end

    def self.parse_environment(name, value)
      case DEFAULTS.fetch(name)
      when Integer then Integer(value, 10)
      when Float then Float(value)
      when Symbol then value.to_sym
      when Hash then JSON.parse(value, symbolize_names: true)
      when true, false
        return true if %w[true 1].include?(value)
        return false if %w[false 0].include?(value)

        raise ArgumentError, "expected true or false"
      else value
      end
    rescue ArgumentError, TypeError, JSON::ParserError => e
      raise ConfigurationError, "Invalid GRITZ_#{name.to_s.upcase}: #{e.message}"
    end

    def validate!
      DEFAULTS.each do |name, default|
        value = public_send(name)
        valid = case default
                when Integer then value.is_a?(Integer) && value.between?(name == :workers ? 0 : 1, 2_147_483_647)
                when Float then value.is_a?(Numeric) && value.real? && value.finite? && value.between?(0, 2_147_483.647)
                when true, false then [true, false].include?(value)
                else value.is_a?(default.class)
                end
        raise ConfigurationError, "Invalid #{name}: #{value.inspect}" unless valid
      end
      %i[shutdown_timeout worker_boot_timeout worker_timeout status_interval].each do |name|
        raise ConfigurationError, "#{name} must be positive" unless public_send(name).positive?
      end
      ENUMS.each do |name, allowed|
        raise ConfigurationError, "#{name} must be one of #{allowed.join(', ')}" unless allowed.include?(public_send(name))
      end
      validate_addresses!
      validate_recycle!
      validate_tls!
      raise ConfigurationError, "controllers must be an Array of classes" unless controllers.is_a?(Array) && controllers.all?(Class)
      raise ConfigurationError, "middleware must be a Stack" unless middleware.is_a?(Middleware::Stack)
      raise ConfigurationError, "preload_app must be boolean" unless [true, false].include?(preload_app)

      self
    end

    def preload_app? = preload_app

    # Fail before allocating transport resources for unsupported release features.
    def validate_runtime!
      validate!
      raise ConfigurationError, "This release supports transport :native" unless transport == :native
      raise ConfigurationError, "This release supports listener_strategy :reuseport" unless listener_strategy == :reuseport
      raise ConfigurationError, "TLS is planned for v0.3" unless tls.empty?
      raise ConfigurationError, "worker_recycle is planned for v0.3" unless worker_recycle.empty?
      raise ConfigurationError, "Health checks are planned for v0.3" unless health_checks.empty?
      raise ConfigurationError, "This release supports log_format :json" unless log_format == :json
      raise ConfigurationError, "This release reserves metrics_backend :pipe; metrics export is planned for v0.3" unless metrics_backend == :pipe
      raise ConfigurationError, "grpc_fork_support requires workers > 0" if workers.zero? && fork_mode != :clean
      raise ConfigurationError, "at least one controller must be registered" if controllers.empty?

      self
    end

    def validate_single_process!
      validate_runtime!
      raise ConfigurationError, "Testing::Server requires workers 0; use Testing::Cluster for supervised servers" unless workers.zero?

      self
    end

    def add_preloader(&block)
      @preload_app = true
      @preloaders << block if block
    end

    def preload!
      @preloaders.each(&:call)
    end

    def add_hook(name, &block)
      raise ConfigurationError, "#{name} requires a block" unless block

      @hooks.fetch(name) << block
    end

    def run_hooks(name, *args)
      @hooks.fetch(name).each { |hook| hook.call(*args) }
    end

    def server_args
      {
        "grpc.so_reuseport" => listener_strategy == :reuseport ? 1 : 0,
        "grpc.max_connection_age_ms" => (max_connection_age * 1000).to_i,
        "grpc.max_connection_age_grace_ms" => (max_connection_age_grace * 1000).to_i,
        "grpc.keepalive_time_ms" => (keepalive_time * 1000).to_i,
        "grpc.keepalive_permit_without_calls" => keepalive_permit_without_calls ? 1 : 0,
        "grpc.max_receive_message_length" => max_receive_message_size,
        "grpc.max_send_message_length" => max_send_message_size,
        "grpc.max_metadata_size" => max_metadata_size
      }
    end

    private

    def validate_addresses!
      %i[bind admin_bind].each do |name|
        match = /\A(?:\[[^\]\s]+\]|[^:\s]+):(\d+)\z/.match(public_send(name))
        raise ConfigurationError, "#{name} must be a host:port address" unless match && match[1].to_i <= 65_535
      end
      if listener_strategy == :reuseport && workers > 1 && bind.end_with?(":0")
        raise ConfigurationError, "reuseport with multiple workers cannot use port 0"
      end
      if transport == :native && listener_strategy == :inherited_fd
        raise ConfigurationError, "native does not support inherited_fd"
      end
      return unless fork_mode == :grpc_fork_support && !RUBY_PLATFORM.include?("linux")

      raise ConfigurationError, "grpc_fork_support requires Linux"
    end

    def validate_recycle!
      worker_recycle.each do |name, value|
        valid = if name == :jitter
                  value.is_a?(Numeric) && value.real? && value.finite? && value.between?(0, 1)
                elsif %i[max_requests max_rss_mb max_pss_mb max_lifetime].include?(name)
                  value.is_a?(Numeric) && value.real? && value.finite? && value.positive? && (name != :max_requests || value.is_a?(Integer))
                end
        raise ConfigurationError, "Invalid worker_recycle #{name}" unless valid
      end
    end

    def validate_tls!
      return if tls.empty?

      unless %i[cert key].all? { |name| tls[name].is_a?(String) && File.readable?(tls[name]) }
        raise ConfigurationError, "tls requires readable cert and key files"
      end

      tls.each do |name, path|
        raise ConfigurationError, "Invalid tls #{name}" unless %i[cert key client_ca].include?(name) && path.is_a?(String) && File.readable?(path)
      end
    end
  end
end
