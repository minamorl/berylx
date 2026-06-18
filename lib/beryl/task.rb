# frozen_string_literal: true

module Beryl
  class Task
    def self.[](name, &block)
      new(name, &block)
    end

    def self.build(name, &block)
      self[name, &block]
    end

    attr_reader :name

    def initialize(name, &block)
      raise ArgumentError, 'Task requires a block' unless block

      @name = name.to_sym
      @block = block
    end

    def call(focus)
      root = Result.coerce_focus(focus)
      Result.normalize(@block.call(root))
    rescue StandardError => e
      Result.err(root || focus, e.class.name.to_sym, e.message, cause: e)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def |(other)
      self >> other
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
