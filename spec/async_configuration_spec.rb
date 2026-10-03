# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Async configuration" do
  def config
    Gritz::Configuration.new.tap do |value|
      value.transport = :async
      value.listener_strategy = :inherited_fd
      value.controllers = [Class.new]
    end
  end

  it "accepts inherited listeners with multiple workers on one ephemeral port" do
    settings = config
    settings.workers = 2
    settings.bind = "127.0.0.1:0"
    expect(settings.validate_runtime!).to equal(settings)
  end

  it "allows async reuseport but rejects native-specific fork support" do
    settings = config
    settings.listener_strategy = :reuseport
    expect(settings.validate_single_process!).to equal(settings)
    settings.workers = 1
    settings.fork_mode = :grpc_fork_support
    expect { settings.validate_runtime! }.to raise_error(Gritz::ConfigurationError, /native/)
  end

  it "allows recycling on an ephemeral inherited listener" do
    settings = config
    settings.workers = 2
    settings.bind = "127.0.0.1:0"
    settings.worker_recycle = { max_requests: 10 }
    expect(settings.validate_runtime!).to equal(settings)
  end
end
