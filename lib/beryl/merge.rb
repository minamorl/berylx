# frozen_string_literal: true

module Beryl
  module Merge
    module_function

    def keep_left
      ->(left, _right) { left }
    end

    def keep_right
      ->(_left, right) { right }
    end

    def deep
      lambda do |left, right|
        Focus[deep_merge(left.to_h, right.to_h)]
      end
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end
  end
end
