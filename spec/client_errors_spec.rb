# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Downstream error boundaries" do
  let(:context) { Struct.new(:store).new({}) }

  it "preserves an optional Async deadline without loading its adapter" do
    stub_const("Async::GRPC::DeadlineExceededError", Class.new(StandardError))
    error = Async::GRPC::DeadlineExceededError.new("timeout")
    mapper = Gritz::Middleware::ExceptionMapper.new(->(_context) { raise error })
    expect { mapper.call(context) }.to raise_error(Gritz::Errors::DeadlineExceeded, "deadline exceeded")
    expect(context.store).to be_empty
  end

  it "keeps canonical error classes while identifying decoded remote errors" do
    local = Gritz::Errors::NotFound.new("local")
    remote = Gritz::Errors::NotFound.new("remote", remote: true, details: ["details"], metadata: { "reason" => "missing" })
    expect(local).not_to be_remote
    expect(remote).to be_remote
    expect(remote).to have_attributes(code: :not_found, grpc_code: 5, details: ["details"], metadata: { "reason" => "missing" })
  end

  it "maps an uncaught remote error to a safe internal error without its trailers or rich details" do
    app = ->(_context) { raise Gritz::Errors::NotFound.new("private downstream resource", remote: true, details: ["private detail"], metadata: { "private" => "secret" }) }
    mapper = Gritz::Middleware::ExceptionMapper.new(app)
    expect { mapper.call(context) }.to raise_error(Gritz::Errors::Internal) do |error|
      expect(error.message).to match(/\Ainternal error \([0-9a-f-]{36}\)\z/)
      expect(error.details).to be_empty
      expect(error.metadata.keys).to eq(["error-id"])
      expect(error).not_to be_remote
    end
    expect(context.store.fetch(:gritz_error)).to include(error: "Gritz::Errors::NotFound", message: "private downstream resource")
  end

  it "allows canonical remote errors to pass through when explicitly enabled" do
    error = Gritz::Errors::PermissionDenied.new("downstream denied", remote: true, metadata: { "reason" => "access" })
    mapper = Gritz::Middleware::ExceptionMapper.new(->(_context) { raise error }, passthrough_remote_errors: true)
    expect { mapper.call(context) }.to(raise_error { |raised| expect(raised).to equal(error) })
    expect(context.store).to be_empty
  end

  it "keeps explicit local application errors unchanged" do
    error = Gritz::Errors::NotFound.new("public application resource")
    mapper = Gritz::Middleware::ExceptionMapper.new(->(_context) { raise error })
    expect { mapper.call(context) }.to(raise_error { |raised| expect(raised).to equal(error) })
  end
end
