# frozen_string_literal: true

module Beryl
  module Prelude
    def Fn(*args, &block)
      Beryl::Fn[*args, &block]
    end

    def State(value = {})
      Beryl::State[value]
    end

    def task(name, &block)
      Beryl.task(name, &block)
    end

    def Ok(value)
      Beryl::Ok.new(value)
    end

    def Err(focus, code, message = code.to_s, cause: nil)
      Beryl::Err.new(focus, code, message, cause)
    end
  end
end
