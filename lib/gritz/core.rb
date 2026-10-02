# frozen_string_literal: true

require "zeitwerk"
require_relative "errors"
require_relative "core/version"

module Gritz
  module Core
    # Core loading deliberately does not require grpc or initialize transports.
    # @api private
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = "gritz-core"
    LOADER.inflector.inflect("dsl" => "DSL", "cli" => "CLI")
    LOADER.push_dir(__dir__, namespace: Gritz)
    LOADER.ignore(__FILE__, File.join(__dir__, "errors.rb"), File.join(__dir__, "core/version.rb"))
    LOADER.do_not_eager_load(File.join(__dir__, "testing/rspec.rb"), File.join(__dir__, "testing/minitest.rb"))
    LOADER.setup
  end
end
