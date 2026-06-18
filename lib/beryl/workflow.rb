# frozen_string_literal: true

module Beryl
  class Workflow
    def self.[](name, &block)
      new(name, block.call)
    end

    attr_reader :name, :body

    def initialize(name, body)
      @name = name.to_sym
      @body = body
    end

    def call(focus)
      Flow[focus].call(@body)
    end

    def >>(other)
      @body >> other
    end

    def &(other)
      @body & other
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(@body, handler, name, &)
    end

    def compile
      Graph.from(@body, name: @name)
    end

    def nodes
      @body.nodes
    end
  end
end
