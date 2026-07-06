# frozen_string_literal: true

module Beryl
  class Parallel
    attr_reader :branches, :reducer, :on_err

    def initialize(branches, reducer = Merge.deep, on_err: :short_circuit)
      @branches = branches.flat_map { _1.is_a?(Parallel) ? _1.branches : _1 }.freeze
      @reducer = reducer
      @on_err = on_err
    end

    def &(other)
      self.class.new(@branches + [other], @reducer, on_err: @on_err)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def reduce(reducer)
      self.class.new(@branches, reducer, on_err: @on_err)
    end

    def short_circuit
      self.class.new(@branches, @reducer, on_err: :short_circuit)
    end

    def accumulate
      self.class.new(@branches, @reducer, on_err: :accumulate)
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    # 実行は EffectTree に一本化。短絡 / accumulate / merge の結果封筒 algebra は
    # EffectTree.run_parallel に集約している (native の二重実装は撤去)。
    def call(focus)
      EffectTree.run(self, focus)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      @branches.flat_map(&:nodes)
    end
  end
end
