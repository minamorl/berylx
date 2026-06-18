# frozen_string_literal: true

module Beryl
  class Parallel
    attr_reader :branches, :reducer

    def initialize(branches, reducer = Merge.keep_right)
      @branches = branches.flat_map { _1.is_a?(Parallel) ? _1.branches : _1 }.freeze
      @reducer = reducer
    end

    def &(other)
      self.class.new(@branches + [other], @reducer)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def reduce(reducer)
      self.class.new(@branches, reducer)
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    def call(focus)
      threads = @branches.map { |branch| Thread.new { branch.call(focus) } }
      branch_results = threads.map(&:value)
      failed = branch_results.find { _1.is_a?(Err) }
      return failed if failed

      merged = branch_results.map(&:focus).reduce(focus) do |acc, branch_focus|
        @reducer.call(acc, branch_focus)
      end

      Result.ok(merged)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      @branches.flat_map(&:nodes)
    end
  end
end
