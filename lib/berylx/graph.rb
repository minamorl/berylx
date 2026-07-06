# frozen_string_literal: true

module Berylx
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
      graph_name = @name || :berylx
      builder = DotBuilder.new
      builder.build(@root)
      lines = ["digraph #{quote(graph_name)} {"]
      builder.lines.each { |line| lines << "  #{line}" }
      lines << '}'
      lines.join("\n")
    end

    private

    def quote(value)
      "\"#{value}\""
    end

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

    # Walks a compiled node tree and emits DOT node declarations and edges.
    # Task names can repeat, so every node gets a stable, index-suffixed id.
    # #build returns [entry_ids, exit_ids] so sequences can chain exits to the
    # next step's entries.
    class DotBuilder
      attr_reader :lines

      def initialize
        @lines = []
        @counter = 0
      end

      def build(node)
        case node
        when Sequence then build_sequence(node)
        when Parallel then build_parallel(node)
        when Branch then build_branch(node)
        when Rescue then build_rescue(node)
        else build_leaf(node.name)
        end
      end

      private

      def build_leaf(name)
        id = next_id(name)
        declare(id)
        [[id], [id]]
      end

      def build_sequence(node)
        entries = nil
        exits = nil
        node.steps.each do |step|
          step_entries, step_exits = build(step)
          entries ||= step_entries
          connect(exits, step_entries) if exits
          exits = step_exits
        end
        [entries || [], exits || []]
      end

      def build_parallel(node)
        split = next_id(:split)
        join = next_id(:join)
        declare(split)
        declare(join)
        node.branches.each do |branch|
          branch_entries, branch_exits = build(branch)
          connect([split], branch_entries)
          connect(branch_exits, [join])
        end
        [[split], [join]]
      end

      def build_branch(node)
        decision = next_id(:branch)
        declare(decision)
        exits = []
        node.arms.each do |arm|
          arm_entries, arm_exits = build(arm.body)
          connect([decision], arm_entries, arm_label(arm.predicate))
          exits.concat(arm_exits)
        end
        [[decision], exits]
      end

      def build_rescue(node)
        body_entries, body_exits = build(node.body)
        handler_entries, handler_exits = build(node.handler)
        connect(body_exits, handler_entries)
        [body_entries, body_exits + handler_exits]
      end

      def arm_label(predicate)
        predicate.else_branch ? 'else' : predicate.name.to_s
      end

      def connect(from_ids, to_ids, label = nil)
        from_ids.each do |from|
          to_ids.each { |to| @lines << edge(from, to, label) }
        end
      end

      def edge(from, to, label)
        attributes = label ? " [label=#{quote(label)}]" : ''
        "#{quote(from)} -> #{quote(to)}#{attributes};"
      end

      def declare(id)
        @lines << "#{quote(id)};"
      end

      def next_id(name)
        id = "#{name}##{@counter}"
        @counter += 1
        id
      end

      def quote(value)
        "\"#{value}\""
      end
    end
  end
end
