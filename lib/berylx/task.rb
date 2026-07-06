# frozen_string_literal: true

module Berylx
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
      result = Result.normalize(@block.call(root))
      result.is_a?(Err) ? with_task_context(result) : result
    rescue StandardError => e
      Result.err(root || focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
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

    private

    def with_task_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
    end
  end
end
