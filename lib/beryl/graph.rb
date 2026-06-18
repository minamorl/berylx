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
      lines << "}"
      lines.join("\n")
    end

    private

    def collect_parallel_nodes(node)
      case node
      when Parallel
        [node.nodes.map(&:name)] + node.branches.flat_map { collect_parallel_nodes(_1) }
      when Sequence
        node.steps.flat_map { collect_parallel_nodes(_1) }
      when Branch
        node.arms.flat_map { collect_parallel_nodes(_1.body) }
      when Rescue
        collect_parallel_nodes(node.body) + collect_parallel_nodes(node.handler)
      else
        []
      end
    end
  end
end
