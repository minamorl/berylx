# frozen_string_literal: true

module Beryl
  class Flow
    def self.[](focus)
      new(focus)
    end

    attr_reader :focus

    def initialize(focus)
      @focus = Result.coerce_focus(focus)
    end

    def call(node)
      node.call(@focus)
    end

    def >>(other)
      call(other)
    end
  end
end
