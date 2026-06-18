# frozen_string_literal: true

module Beryl
  class State
    def self.[](value = {})
      new(Lay[value])
    end

    attr_reader :lay, :node

    def initialize(lay, node = nil)
      @lay = Result.coerce_focus(lay)
      @node = node
    end

    def |(other)
      call(coerce_node(other))
    end

    def &(other)
      next_node = coerce_node(other)
      self.class.new(@lay, @node ? (@node & next_node) : next_node)
    end

    def call(node = nil)
      target = node ? coerce_node(node) : @node
      raise ArgumentError, 'State has no task to run' unless target

      Flow[@lay].call(target)
    end

    def to_lay
      @lay
    end

    private

    def coerce_node(taskish)
      return taskish if taskish.respond_to?(:call)

      raise TypeError, "expected a Beryl task/workflow node, got #{taskish.inspect}"
    end
  end

  def self.State(value = {})
    State[value]
  end

  def self.task(name, &)
    Task.build(name, &)
  end
end
