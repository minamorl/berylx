# frozen_string_literal: true

require 'minitest/autorun'
require 'beryl'
require 'beryl/effect_tree'

# beryl workflow の Sequence(>>) を darkcore の単一 Effect 型へ載せ替えた
# adapter (Beryl::EffectTree) の検証。
#
# 主目的:
#   1. 同一 workflow を legacy 実行 (Beryl.run) と effect_tree 実行
#      (Beryl::EffectTree.run) の両方で走らせ、結果 lay と Err 封筒が
#      一致すること (移行期の dual-run 差分検証)。
#   2. Task を不透明サンクでなく tagged effect ノードで表していること。
#   3. handler 差し替えだけで dry-run (実行せず計画列挙) できること。
class EffectTreeTest < Minitest::Test
  # --- テスト用 workflow ------------------------------------------
  def strip
    Beryl::Task[:strip] { |lay| lay[:name].update(&:strip) }
  end

  def greet
    Beryl::Task[:greet] { |lay| lay[:greeting].set("hello #{lay[:name].get}") }
  end

  def boom
    Beryl::Task[:boom] { |_lay| raise 'kaboom' }
  end

  def domain_reject
    Beryl::Task[:validate] { |lay| lay.reject(:invalid, 'name is blank') }
  end

  # --- lay の突き合わせ用ヘルパ (Focus は == を持たないので to_h 比較) --
  def assert_same_envelope(legacy, effect)
    assert_equal legacy.class, effect.class, 'result class (Ok/Err) must match'

    if legacy.is_a?(Beryl::Ok)
      assert_equal legacy.focus.to_h, effect.focus.to_h, 'Ok lay must match'
    else
      assert_equal legacy.focus.to_h, effect.focus.to_h, 'Err partial_lay must match'
      assert_equal legacy.code, effect.code, 'Err code must match'
      assert_equal legacy.message, effect.message, 'Err message must match'
      assert_equal legacy.failed_node, effect.failed_node, 'Err failed_node must match'
      assert_equal legacy.trace, effect.trace, 'Err trace must match'
    end
  end

  # ================================================================
  # 1. dual-run 差分検証: 成功経路
  # ================================================================
  def test_sequence_success_matches_legacy
    workflow = strip >> greet
    input = { name: '  mina  ' }

    legacy = Beryl.run(workflow, input)
    effect = Beryl::EffectTree.run(workflow, input)

    assert_instance_of Beryl::Ok, effect
    assert_equal({ name: 'mina', greeting: 'hello mina' }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 1'. dual-run 差分検証: 失敗経路 (例外 → Err) の短絡と partial_lay 保持
  # ================================================================
  def test_sequence_exception_error_matches_legacy
    # strip は成功して name を更新、boom で短絡、greet には到達しない。
    workflow = strip >> boom >> greet
    input = { name: '  mina  ' }

    legacy = Beryl.run(workflow, input)
    effect = Beryl::EffectTree.run(workflow, input)

    assert_instance_of Beryl::Err, effect
    assert_equal :boom, effect.failed_node
    # 短絡: boom 直前 (strip 適用済) の partial_lay を保持し、greeting は付かない。
    assert_equal({ name: 'mina' }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 1''. dual-run 差分検証: ドメイン失敗 (lay.reject → Err) も一致
  # ================================================================
  def test_sequence_domain_reject_matches_legacy
    workflow = domain_reject >> greet
    input = { name: '' }

    legacy = Beryl.run(workflow, input)
    effect = Beryl::EffectTree.run(workflow, input)

    assert_instance_of Beryl::Err, effect
    assert_equal :invalid, effect.code
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 1'''. 単一 Task (Sequence でない) も両実行で一致
  # ================================================================
  def test_single_task_matches_legacy
    legacy = Beryl.run(strip, { name: '  mina  ' })
    effect = Beryl::EffectTree.run(strip, { name: '  mina  ' })

    assert_same_envelope(legacy, effect)
    assert_equal({ name: 'mina' }, effect.focus.to_h)
  end

  # ================================================================
  # 2. Task は tagged effect ノードとして表れる (不透明サンクでない)
  # ================================================================
  def test_task_is_a_tagged_effect_node_not_opaque_thunk
    effect = Beryl::EffectTree.build(strip >> greet, { name: '  mina  ' })

    # 木の最初のノードは :beryl_task タグを持ち、payload は [Task, Focus]。
    assert_equal Beryl::EffectTree::TASK, effect.tag
    task, focus = effect.payload

    assert_instance_of Beryl::Task, task
    assert_equal :strip, task.name # payload を検査できる = 不透明でない
    assert_instance_of Beryl::Focus, focus
  end

  # ================================================================
  # 3. handler 差し替えだけで dry-run (実行せず計画列挙)
  # ================================================================
  def test_dry_run_enumerates_plan_without_executing
    # boom は実行されれば raise するが、dry-run は block を呼ばないので安全。
    workflow = strip >> boom >> greet

    dry = Beryl::EffectTree.dry_run(workflow, { name: '  mina  ' })

    # 計画は全ステップを順に列挙する (短絡しない)。
    assert_equal %i[strip boom greet], dry.steps
    # 実行していないので lay は入力のまま (strip も適用されない)。
    assert_instance_of Beryl::Ok, dry.result
    assert_equal({ name: '  mina  ' }, dry.result.focus.to_h)
  end

  def test_dry_run_and_real_run_share_the_same_effect_tree
    # 同一 workflow 本体を書き換えず、handler マップ差し替えだけで
    # real 実行と dry-run を切り替えられること (aspect_via_handler)。
    workflow = strip >> greet

    real = Beryl::EffectTree.run(workflow, { name: '  mina  ' })
    dry  = Beryl::EffectTree.dry_run(workflow, { name: '  mina  ' })

    assert_equal({ name: 'mina', greeting: 'hello mina' }, real.focus.to_h)
    assert_equal %i[strip greet], dry.steps
    # dry-run 側では greet が実行されないので greeting は生えない。
    refute dry.result.focus.to_h.key?(:greeting)
  end
end
