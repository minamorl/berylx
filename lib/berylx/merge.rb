# frozen_string_literal: true

module Berylx
  module Merge
    MISSING = Object.new.freeze

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

    def strict
      lambda do |left, right, base|
        Focus[strict_merge(left.to_h, right.to_h, base.to_h)]
      end
    end

    def deep_merge(left, right)
      left.merge(right) do |_key, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end

    def strict_merge(left, right, base = {}, path = [])
      keys = left.keys | right.keys | base.keys

      keys.each_with_object({}) do |key, merged|
        left_has = left.key?(key)
        right_has = right.key?(key)
        base_has = base.key?(key)

        left_value = left_has ? left.fetch(key) : MISSING
        right_value = right_has ? right.fetch(key) : MISSING
        base_value = base_has ? base.fetch(key) : MISSING

        merged[key] = strict_value(left_value, right_value, base_value, path + [key])
      end
    end

    def strict_value(left, right, base, path)
      value = strict_value_with_missing(left, right)
      return value unless value.equal?(MISSING)

      value = strict_value_with_hash_merge(left, right, base, path)
      return value unless value.equal?(MISSING)

      strict_value_from_changes(left, right, base, path)
    end

    def strict_value_with_missing(left, right)
      return left if right.equal?(MISSING)
      return right if left.equal?(MISSING)

      MISSING
    end

    def strict_value_with_hash_merge(left, right, base, path)
      return MISSING unless left.is_a?(Hash) && right.is_a?(Hash)
      return MISSING unless base.is_a?(Hash) || base.equal?(MISSING)

      strict_merge(left, right, base.equal?(MISSING) ? {} : base, path)
    end

    def strict_value_from_changes(left, right, base, path)
      right_changed = changed_from_base?(right, base)
      left_changed = changed_from_base?(left, base)

      return left unless right_changed
      return right unless left_changed
      return left if left == right

      raise Error[
        :merge_conflict,
        "merge conflict at #{path.join('.')}",
        metadata: { path: path, left: left, right: right, base: base.equal?(MISSING) ? nil : base }
      ]
    end

    def changed_from_base?(value, base)
      return true if base.equal?(MISSING)

      value != base
    end
  end
end
