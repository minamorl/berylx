# frozen_string_literal: true

module Beryl
  Predicate = Data.define(:name, :block, :else_branch)
  BranchArm = Data.define(:predicate, :body)

  class When
    def self.[](name = :when, &block)
      new(name, block, false)
    end

    def initialize(name, block, else_branch)
      raise ArgumentError, "When requires a predicate block" unless block || else_branch

      @predicate = Predicate.new(name.to_sym, block, else_branch)
    end

    def >>(body)
      Branch.new([BranchArm.new(@predicate, body)])
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

    def rescue_with(handler = nil, name = nil, &block)
      Sequence.build_rescue(self, handler, name, &block)
    end

    def call(focus)
      arm = @arms.find { matches?(_1.predicate, focus) }
      return Result.err(focus, :no_branch_matched) unless arm

      arm.body.call(focus)
    end

    def nodes
      @arms.flat_map { _1.body.nodes }
    end

    private

    def matches?(predicate, focus)
      predicate.else_branch || predicate.block.call(focus)
    end
  end
end
