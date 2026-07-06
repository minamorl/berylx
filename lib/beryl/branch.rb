# frozen_string_literal: true

module Beryl
  Predicate = Data.define(:name, :block, :else_branch)
  BranchArm = Data.define(:predicate, :body)

  class When
    def self.[](name = :when, &block)
      new(name, block, false)
    end

    def initialize(name, block, else_branch)
      raise ArgumentError, 'When requires a predicate block' unless block || else_branch

      @predicate = Predicate.new(name.to_sym, block, else_branch)
    end

    def >>(other)
      Branch.new([BranchArm.new(@predicate, other)])
    end
  end

  Else = When.new(:else, nil, true)

  class Branch
    attr_reader :arms

    def initialize(arms)
      @arms = arms.freeze
    end

    def |(other)
      self.class.new(@arms + other.arms)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    # 実行は EffectTree に一本化。arm 選択と no_branch_matched の algebra は
    # EffectTree.run_branch に集約している。
    def call(focus)
      EffectTree.run(self, focus)
    end

    def nodes
      @arms.flat_map { _1.body.nodes }
    end
  end
end
