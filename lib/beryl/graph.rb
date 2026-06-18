# frozen_string_literal: true

module Beryl
  class Graph
    def self.from(node, name: nil)
      new(name, node)
    end

    attr_reader :name, :root

    def initialize(name, root)
      @name = name
      @root = root
    end

    def nodes
      @root.nodes.map(&:name)
    end

    def parallel_nodes
      collect_parallel_nodes(@root)
    end

    def to_dot
      graph_name = @name || :beryl
      lines = ["digraph #{graph_name} {"]
      nodes.each { |node| lines << "  #{node};" }
      lines << '}'
      lines.join("\n")
    end

    private

    def collect_parallel_nodes(node)
      return collect_parallel_branch(node) if node.is_a?(Parallel)
      return node.steps.flat_map { collect_parallel_nodes(_1) } if node.is_a?(Sequence)
      return node.arms.flat_map { collect_parallel_nodes(_1.body) } if node.is_a?(Branch)
      return collect_parallel_nodes(node.body) + collect_parallel_nodes(node.handler) if node.is_a?(Rescue)

      []
    end

    def collect_parallel_branch(node)
      [node.nodes.map(&:name)] + node.branches.flat_map { collect_parallel_nodes(_1) }
    end
  end
end
