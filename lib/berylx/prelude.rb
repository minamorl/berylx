# frozen_string_literal: true

module Berylx
  module Prelude
    def Root(value = {})
      Berylx::Root[value]
    end

    def State(value = {})
      Berylx::State[value]
    end

    def task(name, &block)
      Berylx.task(name, &block)
    end

    def Ok(value)
      Berylx::Ok.new(value)
    end

    def Err(focus, code, message = code.to_s, cause: nil)
      Berylx::Result.err(focus, code, message, cause: cause)
    end
  end
end
