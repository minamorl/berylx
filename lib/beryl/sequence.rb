# frozen_string_literal: true

module Beryl
  class Sequence
    attr_reader :steps

    def initialize(steps)
      @steps = steps.flat_map { _1.is_a?(Sequence) ? _1.steps : _1 }.freeze
    end

    def >>(other)
      self.class.new(@steps + [other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &)
      self.class.build_rescue(self, handler, name, &)
    end

    def self.build_rescue(body, handler = nil, name = nil, &block)
      rescue_handler = block ? RescueBlock.new(name || :rescue, block) : handler

      raise ArgumentError, 'rescue_with requires a task or block' unless rescue_handler

      Rescue.new(body, rescue_handler)
    end

    def call(focus)
      result = Result.ok(focus)

      @steps.each do |step|
        if result.is_a?(Err)
          return result unless step.is_a?(Catch) && step.catches?(result)

          result = step.call_error(result)
          next
        end

        next if step.is_a?(Catch)

        result = step.call(result.focus)
      end

      result
    end

    def compile
      Graph.from(self)
    end

    def nodes
      @steps.flat_map(&:nodes)
    end
  end
end
