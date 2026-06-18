# frozen_string_literal: true

module Beryl
  class RescueBlock
    attr_reader :name

    def initialize(name, block)
      @name = name.to_sym
      @block = block
    end

    def call(focus, error_result)
      Result.normalize(@block.call(error_result.cause || error_result, focus))
    end

    def nodes
      [self]
    end
  end

  class Rescue
    attr_reader :body, :handler

    def initialize(body, handler)
      @body = body
      @handler = handler
    end

    def call(focus)
      result = @body.call(focus)
      return result if result.is_a?(Ok)

      if @handler.is_a?(RescueBlock)
        @handler.call(result.focus, result)
      else
        @handler.call(result.focus)
      end
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

    def nodes
      @body.nodes + @handler.nodes
    end
  end
end
