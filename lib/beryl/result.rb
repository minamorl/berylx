# frozen_string_literal: true

module Beryl
  Ok = Data.define(:focus) do
    def |(other)
      Result.bind(self) { |current| other.call(current) }
    end
  end

  Err = Data.define(:focus, :code, :message, :cause) do
    def |(_other)
      self
    end
  end

  module Result
    module_function

    def ok(value)
      Ok.new(value)
    end

    def err(value, code, message = code.to_s, cause: nil)
      Err.new(value, code, message, cause)
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
      return value if value.respond_to?(:[]) && value.respond_to?(:to_h)

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
