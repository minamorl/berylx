# frozen_string_literal: true

module Beryl
  class Task
    def self.[](name, &block)
      new(name, &block)
    end

    attr_reader :name

    def initialize(name, &block)
      raise ArgumentError, "Task requires a block" unless block

      @name = name.to_sym
      @block = block
    end

    def call(focus)
      Result.normalize(@block.call(focus))
    rescue StandardError => error
      Result.err(focus, error.class.name.to_sym, error.message, cause: error)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &block)
      Sequence.build_rescue(self, handler, name, &block)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      [self]
    end
  end
end
