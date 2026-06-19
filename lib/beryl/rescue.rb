# frozen_string_literal: true

module Beryl
  class RescueBlock
    attr_reader :name

    def initialize(name, block)
      @name = name.to_sym
      @block = block
    end

    def call(focus, error_result)
      result = Result.normalize(@block.call(error_result.cause || error_result.error, focus))
      result.is_a?(Err) ? with_rescue_context(result) : result
    rescue StandardError => e
      Result.err(focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
    end

    def nodes
      [self]
    end

    private

    def with_rescue_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
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
        handler_result = @handler.call(result.focus)
        handler_result.is_a?(Err) ? rescue_failed(result, handler_result) : handler_result
      end
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    def nodes
      @body.nodes + @handler.nodes
    end

    private

    def rescue_failed(original_result, handler_result)
      error =
        handler_result.error.with_context(
          metadata: {
            rescued_error: original_result.error.to_h
          }
        )
      Err.new(handler_result.focus, error)
    end
  end
end
