# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Worker metric backend registration" do
  it "requires an installed recorder for OTLP and validates the factory without running it in the master" do
    config = Gritz::Configuration.new
    config.controllers = [Class.new]
    config.metrics_backend = :otlp
    expect { config.validate_runtime! }.to raise_error(Gritz::ConfigurationError, /recorder/)
    factory = ->(worker:) { raise "allocated in master #{worker}" }
    config.metrics_recorder_factory = factory
    expect(config.validate_runtime!).to eq(config)
    config.metrics_recorder_factory = Object.new
    expect { config.validate! }.to raise_error(Gritz::ConfigurationError, /recorder/)
  end
end
