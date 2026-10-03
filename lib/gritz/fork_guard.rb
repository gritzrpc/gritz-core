# frozen_string_literal: true

module Gritz
  # Detects transport resource constructors in the master before workers fork.
  # @api public
  class ForkGuard
    class Violation < StandardError
      attr_reader :klass, :locations

      def initialize(klass, locations)
        @klass = klass
        @locations = locations
        super("gRPC object was created in the master process before fork.\n  " \
              "#{klass}.new\n#{locations.map { |location| "    from #{location}" }.join("\n")}\n" \
              "Fix: create it in an on_worker_boot hook.")
      end
    end

    # @api private
    module ConstructorHook
      def new(...)
        Gritz::ForkGuard.check!(self)
        super
      end
    end

    attr_reader :mode, :logger, :master_pid, :violations

    class << self
      attr_reader :current

      def activate(mode: :raise, logger: nil, master_pid: Process.pid)
        @current = new(mode:, logger:, master_pid:)
      end

      def deactivate
        @current = nil
      end

      def install(klass)
        klass.singleton_class.prepend(ConstructorHook) unless klass.singleton_class.ancestors.include?(ConstructorHook)
      end

      def master?
        @current&.master? || false
      end

      def check!(klass)
        guard = @current
        return unless guard && guard.mode != :off && guard.master?

        locations = caller_locations(1, 8).reject { |location| location.path == __FILE__ }
        violation = Violation.new(klass, locations)
        guard.violations << violation
        case guard.mode
        when :raise then raise violation
        when :warn
          guard.logger ? guard.logger.warn(violation.message) : Kernel.warn(violation.message)
        end
      end
    end

    def initialize(mode:, logger:, master_pid:)
      raise ArgumentError, "fork guard mode must be :raise, :warn, :off, or :record" unless %i[raise warn off record].include?(mode)

      @mode = mode
      @logger = logger
      @master_pid = master_pid
      @violations = []
    end

    def master?
      Process.pid == @master_pid
    end
  end
end
