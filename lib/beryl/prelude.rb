# frozen_string_literal: true

module Beryl
  module Prelude
    def Fn(*args, &block)
      Beryl::Fn[*args, &block]
    end

    def Root(value = {})
      Beryl::Root[value]
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
      Beryl::Result.err(focus, code, message, cause: cause)
    end
  end
end
