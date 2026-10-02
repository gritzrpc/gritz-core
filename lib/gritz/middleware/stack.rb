# frozen_string_literal: true

module Gritz
  module Middleware
    # Mutable middleware configuration; build creates an immutable call chain.
    # @api public
    class Stack
      Entry = Struct.new(:middleware, :options, :block)
      attr_reader :entries

      def initialize
        @entries = []
      end

      def initialize_copy(other)
        super
        @entries = other.entries.dup
      end

      def self.default
        new.use(RequestId).use(Context).use(Metrics).use(Logging).use(ExceptionMapper)
      end

      def use(middleware, **options, &block)
        entries << Entry.new(middleware, options, block)
        self
      end

      def insert_before(target, middleware, **options, &block)
        entries.insert(index_of(target), Entry.new(middleware, options, block))
        self
      end

      def insert_after(target, middleware, **options, &block)
        entries.insert(index_of(target) + 1, Entry.new(middleware, options, block))
        self
      end

      def swap(target, middleware, **options, &block)
        entries[index_of(target)] = Entry.new(middleware, options, block)
        self
      end

      def delete(middleware)
        entries.reject! { |entry| entry.middleware == middleware }
        self
      end

      def build(app)
        entries.reverse_each.reduce(app) do |endpoint, entry|
          entry.middleware.new(endpoint, **entry.options, &entry.block)
        end
      end

      private

      def index_of(middleware)
        entries.index { |entry| entry.middleware == middleware } || raise(ArgumentError, "middleware not found: #{middleware}")
      end
    end
  end
end
