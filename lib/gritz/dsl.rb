# frozen_string_literal: true

module Gritz
  # Puma-style configuration file evaluator.
  # @api public
  class DSL
    def initialize(config)
      @config = config
    end

    def evaluate(path)
      instance_eval(File.read(path), File.expand_path(path), 1)
    end

    Configuration::DEFAULTS.each_key do |name|
      define_method(name) { |value| @config.public_send("#{name}=", value) }
    end

    Configuration::HOOKS.each do |name|
      define_method(name) { |&block| @config.add_hook(name, &block) }
    end

    def preload_app!(&)
      @config.add_preloader(&)
    end

    def register_controller(*controllers)
      @config.controllers.concat(controllers)
    end

    def middleware
      yield @config.middleware
    end

    def health_check(name, &block)
      raise ConfigurationError, "health_check requires a block" unless block

      @config.health_checks[name] = block
    end

    def method_missing(name, *_args)
      raise ConfigurationError, "Unknown configuration setting #{name}"
    end

    def respond_to_missing?(_name, _include_private = false) = false
  end
end
