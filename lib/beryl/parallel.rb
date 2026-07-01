# frozen_string_literal: true

module Beryl
  class Parallel
    attr_reader :branches, :reducer

    def initialize(branches, reducer = Merge.deep)
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
      failures = branch_results.grep(Err)

      return parallel_error(focus, failures) unless failures.empty?

      merged = merge_results(focus, branch_results)
      return merged if merged.is_a?(Err)

      Result.ok(merged)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      @branches.flat_map(&:nodes)
    end

    private

    def merge_results(focus, branch_results)
      branch_results.map(&:focus).reduce(focus) do |acc, branch_focus|
        call_reducer(acc, branch_focus, focus)
      end
    rescue StandardError => e
      Result.err(focus, Error.from(e, failed_node: :parallel, trace: [:parallel]))
    end

    def call_reducer(left, right, base)
      if @reducer.arity == 3
        @reducer.call(left, right, base)
      else
        @reducer.call(left, right)
      end
    end

    def parallel_error(focus, failures)
      primary = failures.first
      errors = failures.map(&:error)
      error =
        Error[
          :parallel_failed,
          "#{failures.size} parallel branch#{'es' unless failures.size == 1} failed",
          cause: primary.cause,
          failed_node: primary.failed_node,
          trace: primary.trace,
          parallel_errors: errors
        ]

      Err.new(primary.focus || focus, error)
    end
  end
end
