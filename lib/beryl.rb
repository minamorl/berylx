# frozen_string_literal: true

# darkcore は beryl の必須依存。beryl workflow の唯一の実行基盤である
# EffectTree (darkcore Effect 木) が全合成子の実行を担うため、遅延ではなく
# ここで無条件に読み込む。
require 'darkcore'

require_relative 'beryl/version'
require_relative 'beryl/error'
require_relative 'beryl/result'
require_relative 'beryl/focus'
require_relative 'beryl/root'
require_relative 'beryl/flow'
require_relative 'beryl/state'
require_relative 'beryl/merge'

require_relative 'beryl/task'
require_relative 'beryl/sequence'
require_relative 'beryl/parallel'
require_relative 'beryl/branch'
require_relative 'beryl/rescue'
require_relative 'beryl/workflow'
require_relative 'beryl/graph'

# EffectTree は beryl の唯一の実行基盤。全合成子 (Sequence / Parallel / Branch /
# Rescue) の #call はここへ委譲するので、core の一部として無条件に読み込む。
require_relative 'beryl/effect_tree'

require_relative 'beryl/prelude'

module Beryl
  Lay = Focus

  def self.run(workflow, focus)
    Flow[focus].call(workflow)
  end
end
