# frozen_string_literal: true

module Beryl
  class Fn
    def self.[](*names, &block)
      new(names:, block: block || ->(value) { value })
    end

    def initialize(names: [], block:)
      @names = names
      @block = block
    end

    def call(*args)
      @block.call(*args)
    end

    def then(other = nil, &block)
      step = other || self.class.new(block: block)
      self.class.new(block: ->(*args) { step.call(call(*args)) })
    end

    def map(&block)
      self.class.new(block: ->(*args) { block.call(call(*args)) })
    end

    def >>(other)
      then(other)
    end

    def <<(other)
      self.class.new(block: ->(*args) { call(other.call(*args)) })
    end
  end
end
