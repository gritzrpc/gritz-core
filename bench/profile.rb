# frozen_string_literal: true

require "gritz/core"
require "stackprof"
require "json"
require "logger"
require "stringio"

# Keep transport I/O outside the profile to expose dispatcher and middleware allocations.
service = Class.new do
  def self.service_name = "bench.Profile"

  def self.rpc_descs
    { "Unary" => Struct.new(:input, :output) {
      def client_streamer? = false
      def server_streamer? = false
      def bidi_streamer? = false
    }.new(String, String) }
  end
end
controller = Class.new(Gritz::Controller) do
  bind service
  def unary = request.message
end
logger = Logger.new(StringIO.new, level: Logger::WARN)
router = Gritz::Router.new(controllers: [controller], logger:)
dispatcher = Gritz::Dispatcher.new(router:, logger:)
descriptor = router.routes.values.first
iterations = Integer(ENV.fetch("PROFILE_ITERATIONS", "200000"))
call = -> { dispatcher.call(Gritz::Testing::InMemoryCall.new(method_descriptor: descriptor, messages: ["hello"])) }
10_000.times { call.call }
measurements = 3.times.map do
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { call.call }
  { seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
    allocated_objects: GC.stat(:total_allocated_objects) - allocated }
end
result = StackProf.run(mode: :cpu, interval: 1000) { iterations.times { call.call } }
frames = result.fetch(:frames).values.sort_by { |frame| -frame[:total_samples] }.first(20)
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, iterations:, measurements:, samples: result[:samples],
                          missed_samples: result[:missed_samples], frames: frames.map { |frame| frame.slice(:name, :file, :line, :samples, :total_samples) })
