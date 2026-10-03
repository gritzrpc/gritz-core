# frozen_string_literal: true

require "optparse"
require "logger"
require "rbconfig"
require "socket"
require "net/http"
require "json"

module Gritz
  # Starts and operates servers, lists routes, or checks configuration and fork safety.
  # @api public
  class CLI
    CHILD_BOOTSTRAP = <<~RUBY
      require "socket"
      fd = ENV.delete("GRITZ_INTERNAL_OWNER_FD")
      exit Gritz::CLI.new(owner_io: UNIXSocket.for_fd(Integer(fd))).run(ARGV)
    RUBY

    def self.child_command(argv)
      library = defined?(Transport::Async) ? "gritz/async" : "gritz/core"
      [RbConfig.ruby, "-I", $LOAD_PATH.join(File::PATH_SEPARATOR), "-r#{library}", "-e", CHILD_BOOTSTRAP, "--", *argv]
    end

    def initialize(stdout: $stdout, stderr: $stderr, env: ENV, status_io: nil, owner_io: nil, launch: false, launch_command: nil)
      @stdout = stdout
      @stderr = stderr
      @env = env
      @status_io = status_io
      @owner_channel = Supervisor::StatusChannel.new(owner_io) if owner_io
      @launch = launch
      @launch_command = launch_command
    end

    def run(argv)
      args = argv.dup
      path = nil
      overrides = {}
      parser = OptionParser.new do |options|
        options.banner = "Usage: gritz [start|routes|check|stats|stop|restart] [-C config/gritz.rb] [options]"
        options.on("-C", "--config PATH", "Configuration file") { |value| path = value }
        options.on("--workers N", Integer) { |value| overrides[:workers] = value }
        options.on("--threads N", Integer) { |value| overrides[:threads] = value }
        options.on("--bind ADDRESS") { |value| overrides[:bind] = value }
        options.on("--admin-bind ADDRESS", "Admin HTTP host:port (operations do not load config)") { |value| overrides[:admin_bind] = value }
        options.on("--pid-file PATH", "Active master PID file; operations fall back if Admin is unavailable") { |value| overrides[:pid_file] = value }
        options.on("--strict-routes") { overrides[:strict_routes] = true }
        options.on("-v", "--version") {
          @stdout.puts(Core::VERSION)
          return 0
        }
        options.on("-h", "--help") {
          @stdout.puts(options)
          return 0
        }
      end
      parser.parse!(args)
      command = args.shift || "start"
      raise ConfigurationError, "Unknown command #{command}" unless %w[start routes check stats stop restart].include?(command)
      raise ConfigurationError, "Unexpected argument #{args.first}" unless args.empty?

      if %w[stats stop restart].include?(command)
        raise ConfigurationError, "#{command} does not load configuration; use --admin-bind or --pid-file instead of -C" if path

        return run_operation(command, overrides)
      end

      logger = Logger.new(@stdout)
      logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
      if command == "start" && @launch && !@owner_channel
        return Supervisor::Launcher.new(command: @launch_command || self.class.child_command(argv), env: @env,
                                        stdout: @stdout, stderr: @stderr, logger: logger, status_io: @status_io).run
      end

      path ||= "config/gritz.rb" if File.file?("config/gritz.rb")
      guard = ForkGuard.activate(mode: :record) if command != "routes"
      if command != "routes" && Gem.loaded_specs.key?("gritz-native") && !defined?(Transport::Async)
        require "gritz/native"
      end
      config = Configuration.load(path: path, env: @env, overrides: overrides)
      if command == "check"
        config.preload! if config.preload_app?
        guard.violations.each { |violation| @stderr.puts(violation.message) }
        return 1 unless guard.violations.empty?

        config.validate_runtime!
        require "gritz/#{config.transport}"
        Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
        @stdout.puts "Configuration and fork safety checks passed"
      elsif command == "start"
        config.validate_runtime!
        require "gritz/#{config.transport}"
        if config.workers.positive? && config.fork_mode == :clean
          raise guard.violations.first if config.fork_guard == :raise && !guard.violations.empty?

          guard.violations.each { |violation| logger.warn(violation.message) } if config.fork_guard == :warn
        end
        @stdout.sync = true if @stdout.respond_to?(:sync=)
        @owner_channel&.write(type: "configured", pid: Process.pid, workers: config.workers, bind: config.bind,
                              admin_bind: config.admin_bind, min_ready_workers: config.min_ready_workers, pid_file: config.pid_file,
                              reexec_timeout: config.reexec_timeout, drain_delay: config.drain_delay, shutdown_timeout: config.shutdown_timeout,
                              listener_strategy: config.listener_strategy.to_s)
        if @owner_channel && config.listener_strategy == :inherited_fd
          until @owner_channel.flush
            raise ConfigurationError, "listener owner closed its control channel" if @owner_channel.closed?

            @owner_channel.io.wait_writable(0.01)
          end
          begin
            listener = @owner_channel.io.recv_io(Socket)
          rescue IOError, SocketError => e
            raise ConfigurationError, "listener owner failed to pass its socket: #{e.message}"
          end
        end
        if config.workers.positive?
          return Supervisor::Master.new(config, logger: logger, status_io: @status_io, owner_channel: @owner_channel, listener:).run
        end

        ForkGuard.deactivate
        config.preload! if config.preload_app?
        return Worker::Runner.new(index: 0, config: config, logger: logger, owner_channel: @owner_channel, listener:).run
      else
        config.preload! if config.preload_app?
        router = Router.new(controllers: config.controllers, strict: config.strict_routes, logger: logger)
      end
      if command == "routes"
        router.routes.each_value do |route|
          @stdout.puts "#{route.full_name} #{route.kind} #{route.controller}##{route.action}"
        end
      end
      0
    rescue ConfigurationError, ForkGuard::Violation, ArgumentError, Errno::ENOENT, SyntaxError, LoadError, RuntimeError => e
      @stderr.puts "gritz: #{e.message}"
      1
    ensure
      ForkGuard.deactivate if guard
      @owner_channel&.close
      listener&.close unless listener&.closed?
    end

    private

    def run_operation(command, overrides)
      address = overrides.fetch(:admin_bind) { @env.fetch("GRITZ_ADMIN_BIND", Configuration::DEFAULTS[:admin_bind]) }
      path = overrides.fetch(:pid_file) { @env.fetch("GRITZ_PID_FILE", "") }
      file_pid = read_pid_file(path) unless path.empty? || command == "stats"
      status = read_admin_status(address, fallback: !file_pid.nil?)
      if command == "stats"
        @stdout.puts "State: #{status.fetch('state')}  Master PID: #{status.fetch('pid')}  Owner PID: #{status['owner_pid'] || 'n/a'}"
        @stdout.puts "WORKER  PID  STATE  RSS  PSS"
        status.fetch("workers").each do |worker|
          @stdout.puts "#{worker['index']}  #{worker.fetch('pid')}  #{worker.fetch('state')}  " \
                       "#{format_bytes(worker['rss_bytes'])}  #{format_bytes(worker['pss_bytes'])}"
        end
      else
        if status && file_pid && status.fetch("pid") != file_pid
          raise ConfigurationError, "Admin master PID #{status.fetch('pid')} does not match PID file #{file_pid}"
        end

        pid = status ? status.fetch("owner_pid", status.fetch("pid")) : file_pid
        signal = command == "stop" ? "TERM" : "USR2"
        begin
          Process.kill(signal, pid)
        rescue SystemCallError => e
          raise ConfigurationError, "Cannot send #{signal} to PID #{pid}: #{e.message}"
        end
        @stdout.puts "Sent #{signal} to PID #{pid}"
      end
      0
    end

    def read_pid_file(path)
      File.open(path, File::RDONLY | File::NONBLOCK) do |file|
        raise ConfigurationError, "PID file must be a regular file: #{path}" unless file.stat.file?
        raise ConfigurationError, "Invalid PID file: #{path}" if file.stat.size > 64

        value = file.read(65).to_s.strip
        raise ConfigurationError, "Invalid PID file: #{path}" unless value.match?(/\A[0-9]{1,10}\z/)

        validate_pid!(Integer(value, 10))
      end
    rescue SystemCallError => e
      raise ConfigurationError, "Cannot read PID file #{path}: #{e.message}"
    end

    def read_admin_status(address, fallback:)
      match = address.match(/\A(\[[a-zA-Z0-9_.:%-]+\]|[a-zA-Z0-9_.-]+):([0-9]+)\z/)
      raise ConfigurationError, "Invalid Admin address: #{address}" unless match && Integer(match[2], 10).between?(1, 65_535)

      # Operations always target the requested endpoint, never an environment HTTP proxy.
      http = Net::HTTP.new(match[1].delete_prefix("[").delete_suffix("]"), Integer(match[2], 10), nil)
      http.open_timeout = http.read_timeout = 2
      http.max_retries = 0
      body = +""
      response_started = false
      http.start do |client|
        client.request(Net::HTTP::Get.new("/status")) do |response|
          response_started = true
          raise ConfigurationError, "Admin /status returned HTTP #{response.code}" unless response.code == "200"

          response.ignore_eof = false
          response.read_body do |chunk|
            raise ConfigurationError, "Admin /status response exceeds 1 MiB" if body.bytesize + chunk.bytesize > 1_048_576

            body << chunk
          end
        end
      end
      validate_status!(JSON.parse(body))
    rescue SystemCallError, IOError, SocketError, Timeout::Error => e
      return nil if fallback && !response_started

      raise ConfigurationError, "Admin /status unavailable at #{address}: #{e.message}; stop/restart can use --pid-file"
    rescue JSON::ParserError, Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError => e
      raise ConfigurationError, "Invalid Admin /status response: #{e.message}"
    end

    def validate_pid!(pid)
      unless pid.is_a?(Integer) && pid.between?(2, 2_147_483_647) && pid != Process.pid
        raise ConfigurationError, "Invalid server PID: #{pid.inspect}"
      end

      pid
    end

    def validate_status!(status)
      unless status.is_a?(Hash) && %w[starting running draining].include?(status["state"]) && status["workers"].is_a?(Array)
        raise ConfigurationError, "Invalid Admin /status process state"
      end

      validate_pid!(status["pid"])
      validate_pid!(status["owner_pid"]) if status.key?("owner_pid")
      status["workers"].each do |worker|
        unless worker.is_a?(Hash) && Supervisor::WorkerHandle::STATES.include?(worker["state"]) &&
               worker["index"].is_a?(Integer) && worker["index"] >= 0
          raise ConfigurationError, "Invalid Admin /status worker state"
        end

        validate_pid!(worker["pid"])
        %w[rss_bytes pss_bytes].each do |name|
          value = worker[name]
          unless value.nil? || (value.is_a?(Numeric) && value.real? && value.finite? && value >= 0)
            raise ConfigurationError, "Invalid Admin /status #{name}"
          end
        end
      end
      status
    end

    def format_bytes(value) = value ? format("%.2f MiB", value / (1024.0 * 1024)) : "n/a"
  end
end
