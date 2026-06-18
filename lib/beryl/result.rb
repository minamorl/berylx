# frozen_string_literal: true

module Beryl
  Ok = Data.define(:focus)
  Err = Data.define(:focus, :code, :message, :cause)

  module Result
    module_function

    def ok(focus)
      Ok.new(focus)
    end

    def err(focus, code, message = code.to_s, cause: nil)
      Err.new(focus, code, message, cause)
    end

    def normalize(value)
      case value
      when Ok, Err
        value
      else
        ok(value)
      end
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
