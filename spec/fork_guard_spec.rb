# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gritz::ForkGuard do
  before do
    described_class.deactivate
    stub_const("GuardedClient", Class.new do
      attr_reader :value

      def initialize(value: 1)
        @value = block_given? ? yield(value) : value
      end
    end)
    described_class.install(GuardedClient)
  end

  after { described_class.deactivate }

  it "blocks a master constructor and reports the actual calling location" do
    guard = described_class.activate
    expect(described_class.master?).to be true
    expect { GuardedClient.new }.to raise_error(described_class::Violation, /GuardedClient.new.*fork_guard_spec.rb/m)
    expect(guard.violations.size).to eq(1)
    expect(guard.violations.first.klass).to eq(GuardedClient)
    expect(guard.violations.first.locations.first.path).to eq(__FILE__)
  end

  it "warns, records, and forwards keyword arguments and the block" do
    logger = double("logger")
    expect(logger).to receive(:warn).with(/GuardedClient.new/)
    guard = described_class.activate(mode: :warn, logger:)
    expect(GuardedClient.new(value: 3) { |value| value * 2 }.value).to eq(6)
    expect(guard.violations.size).to eq(1)
  end

  it "writes warnings to stderr when no logger is configured" do
    described_class.activate(mode: :warn)
    expect { GuardedClient.new }.to output(/GuardedClient.new/).to_stderr
  end

  it "records without warning for the check command" do
    guard = described_class.activate(mode: :record)
    expect { GuardedClient.new }.not_to output.to_stderr
    expect(guard.violations.first).to be_a(described_class::Violation)
  end

  it "bypasses checks when disabled or deactivated" do
    guard = described_class.activate(mode: :off)
    expect(GuardedClient.new.value).to eq(1)
    expect(guard.violations).to be_empty
    described_class.deactivate
    expect(described_class.current).to be_nil
    expect(described_class.master?).to be false
    expect(GuardedClient.new.value).to eq(1)
  end

  it "installs the constructor hook once" do
    described_class.install(GuardedClient)
    guard = described_class.activate(mode: :record)
    GuardedClient.new
    expect(guard.violations.size).to eq(1)
  end

  it "allows constructors after fork without recording master violations" do
    guard = described_class.activate
    pid = fork do
      client = GuardedClient.new(value: 5)
      exit!(client.value == 5 && guard.violations.empty? && !described_class.master? ? 0 : 1)
    rescue StandardError
      exit! 1
    end
    _, status = Process.waitpid2(pid)
    expect(status).to be_success
    expect(guard.violations).to be_empty
  end

  it "rejects unknown modes" do
    expect { described_class.activate(mode: :ignore) }.to raise_error(ArgumentError, /mode/)
  end
end
