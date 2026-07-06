# frozen_string_literal: true

module Berylx
  Ok = Data.define(:focus) do
    def |(other)
      Result.bind(self) { |current| other.call(current) }
    end
  end

  Err = Data.define(:focus, :error) do
    def unwrap
      raise error.unwrap
    end

    def to_exception
      error.to_exception
    end

    def code
      error.code
    end

    def message
      error.message
    end

    def cause
      error.cause
    end

    def failed_node
      error.failed_node
    end

    def trace
      error.trace
    end

    def parallel_errors
      error.parallel_errors
    end

    def deconstruct
      [focus, code, message, cause]
    end

    def deconstruct_keys(keys)
      values = {
        focus: focus,
        error: error,
        code: code,
        message: message,
        cause: cause,
        failed_node: failed_node,
        trace: trace,
        parallel_errors: parallel_errors
      }
      keys ? values.slice(*keys) : values
    end

    def |(_other)
      self
    end
  end

  module Result
    module_function

    def ok(value)
      Ok.new(value)
    end

    def err(value, code_or_error, message = nil, **context)
      error =
        if code_or_error.is_a?(Error)
          code_or_error.with_context(**context)
        else
          Error[code_or_error, message || code_or_error.to_s, **context]
        end

      Err.new(value, error)
    end

    def normalize(value)
      case value
      when Ok, Err
        value
      else
        ok(value)
      end
    end

    def coerce_focus(value)
      return value if value.is_a?(Focus)

      Focus[value]
    end

    def map(result, &block)
      case result
      in Ok(focus)
        normalize(block.call(focus))
      in Err
        result
      end
    end

    def bind(result, &block)
      case result
      in Ok(focus)
        normalize(block.call(focus))
      in Err
        result
      end
    end
  end
end
