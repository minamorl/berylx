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

    # 実行は EffectTree (darkcore Effect 木) に一本化。短絡・Catch 境界の
    # 回復といった結果封筒の algebra は EffectTree 側に集約している。
    def call(focus)
      EffectTree.run(self, focus)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      @steps.flat_map(&:nodes)
    end
  end
end
