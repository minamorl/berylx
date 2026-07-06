# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# darkcore substrate は berylx の必須依存。EffectTree は core (require 'berylx') の
# 一部として無条件に読み込まれるので、ここでの遅延 require / skip ガードは不要。

# berylx workflow の Sequence(>>) を darkcore の単一 Effect 型へ載せ替えた
# adapter (Berylx::EffectTree) の検証。
#
# 主目的:
#   1. 同一 workflow を legacy 実行 (Berylx.run) と effect_tree 実行
#      (Berylx::EffectTree.run) の両方で走らせ、結果 lay と Err 封筒が
#      一致すること (移行期の dual-run 差分検証)。
#   2. Task を不透明サンクでなく tagged effect ノードで表していること。
#   3. handler 差し替えだけで dry-run (実行せず計画列挙) できること。
class EffectTreeTest < Minitest::Test
  # --- テスト用 workflow ------------------------------------------
  def strip
    Berylx::Task[:strip] { |lay| lay[:name].update(&:strip) }
  end

  def greet
    Berylx::Task[:greet] { |lay| lay[:greeting].set("hello #{lay[:name].get}") }
  end

  def boom
    Berylx::Task[:boom] { |_lay| raise 'kaboom' }
  end

  def domain_reject
    Berylx::Task[:validate] { |lay| lay.reject(:invalid, 'name is blank') }
  end

  # --- 第二段 (parallel / branch / rescue) 用の workflow 部品 --------
  def set_a
    Berylx::Task[:set_a] { |lay| lay[:a].set(1) }
  end

  def set_b
    Berylx::Task[:set_b] { |lay| lay[:b].set(2) }
  end

  def positive_arm
    Berylx::When[:pos] { |lay| lay[:n].get.positive? } >>
      Berylx::Task[:mark_positive] { |lay| lay[:sign].set(:positive) }
  end

  def else_arm
    Berylx::Else >> Berylx::Task[:mark_negative] { |lay| lay[:sign].set(:negative) }
  end

  # --- lay の突き合わせ用ヘルパ (Focus は == を持たないので to_h 比較) --
  def assert_same_envelope(legacy, effect)
    assert_equal legacy.class, effect.class, 'result class (Ok/Err) must match'

    if legacy.is_a?(Berylx::Ok)
      assert_equal legacy.focus.to_h, effect.focus.to_h, 'Ok lay must match'
    else
      assert_equal legacy.focus.to_h, effect.focus.to_h, 'Err partial_lay must match'
      assert_equal legacy.code, effect.code, 'Err code must match'
      assert_equal legacy.message, effect.message, 'Err message must match'
      if legacy.failed_node.nil?
        assert_nil effect.failed_node, 'Err failed_node must match'
      else
        assert_equal legacy.failed_node, effect.failed_node, 'Err failed_node must match'
      end

      assert_equal legacy.trace, effect.trace, 'Err trace must match'
      assert_equal(
        legacy.parallel_errors.map(&:to_h),
        effect.parallel_errors.map(&:to_h),
        'Err parallel_errors must match'
      )
    end
  end

  # ================================================================
  # 1. dual-run 差分検証: 成功経路
  # ================================================================
  def test_sequence_success_matches_legacy
    workflow = strip >> greet
    input = { name: '  mina  ' }

    legacy = Berylx.run(workflow, input)
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
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

    legacy = Berylx.run(workflow, input)
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
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

    legacy = Berylx.run(workflow, input)
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
    assert_equal :invalid, effect.code
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 1'''. 単一 Task (Sequence でない) も両実行で一致
  # ================================================================
  def test_single_task_matches_legacy
    legacy = Berylx.run(strip, { name: '  mina  ' })
    effect = Berylx::EffectTree.run(strip, { name: '  mina  ' })

    assert_same_envelope(legacy, effect)
    assert_equal({ name: 'mina' }, effect.focus.to_h)
  end

  # ================================================================
  # 2. Task は tagged effect ノードとして表れる (不透明サンクでない)
  # ================================================================
  def test_task_is_a_tagged_effect_node_not_opaque_thunk
    effect = Berylx::EffectTree.build(strip >> greet, { name: '  mina  ' })

    # 木の最初のノードは :berylx_task タグを持ち、payload は [Task, Focus]。
    assert_equal Berylx::EffectTree::TASK, effect.tag
    task, focus = effect.payload

    assert_instance_of Berylx::Task, task
    assert_equal :strip, task.name # payload を検査できる = 不透明でない
    assert_instance_of Berylx::Focus, focus
  end

  # ================================================================
  # 3. handler 差し替えだけで dry-run (実行せず計画列挙)
  # ================================================================
  def test_dry_run_enumerates_plan_without_executing
    # boom は実行されれば raise するが、dry-run は block を呼ばないので安全。
    workflow = strip >> boom >> greet

    dry = Berylx::EffectTree.dry_run(workflow, { name: '  mina  ' })

    # 計画は全ステップを順に列挙する (短絡しない)。
    assert_equal %i[strip boom greet], dry.steps
    # 実行していないので lay は入力のまま (strip も適用されない)。
    assert_instance_of Berylx::Ok, dry.result
    assert_equal({ name: '  mina  ' }, dry.result.focus.to_h)
  end

  def test_dry_run_and_real_run_share_the_same_effect_tree
    # 同一 workflow 本体を書き換えず、handler マップ差し替えだけで
    # real 実行と dry-run を切り替えられること (aspect_via_handler)。
    workflow = strip >> greet

    real = Berylx::EffectTree.run(workflow, { name: '  mina  ' })
    dry  = Berylx::EffectTree.dry_run(workflow, { name: '  mina  ' })

    assert_equal({ name: 'mina', greeting: 'hello mina' }, real.focus.to_h)
    assert_equal %i[strip greet], dry.steps
    # dry-run 側では greet が実行されないので greeting は生えない。
    refute dry.result.focus.to_h.key?(:greeting)
  end

  # ================================================================
  # 4. Parallel — dual-run 差分検証 (成功 / short_circuit / accumulate)
  # ================================================================
  def test_parallel_success_matches_legacy
    workflow = set_a & set_b # 既定 reducer Merge.deep, on_err :short_circuit
    input = { base: 0 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
    assert_equal({ base: 0, a: 1, b: 2 }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  def test_parallel_short_circuit_matches_legacy
    # 既定は short_circuit: 最初の失敗ブランチ (branch 順) の Err だけを返す。
    workflow = boom & domain_reject
    input = { name: '' }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
    assert_equal :boom, effect.failed_node
    assert_empty effect.parallel_errors # short_circuit は集約しない
    assert_same_envelope(legacy, effect)
  end

  def test_parallel_accumulate_matches_legacy
    # accumulate はタグ上書き: 全失敗を parallel_errors に集約する。
    workflow = (boom & domain_reject).accumulate
    input = { name: '' }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
    assert_equal :parallel_failed, effect.code
    assert_equal 2, effect.parallel_errors.size
    assert_equal %i[RuntimeError invalid], effect.parallel_errors.map(&:code)
    assert_same_envelope(legacy, effect)
  end

  def test_parallel_default_is_short_circuit
    # result.parallel_default: 明示しなければ short_circuit で走る。
    workflow = boom & domain_reject

    effect = Berylx::EffectTree.run(workflow, { name: '' })

    assert_instance_of Berylx::Err, effect
    refute_equal :parallel_failed, effect.code # 集約していない = short_circuit
    assert_empty effect.parallel_errors
  end

  # ================================================================
  # 5. Branch — dual-run 差分検証 (match / no_branch_matched)
  # ================================================================
  def test_branch_match_matches_legacy
    workflow = positive_arm | else_arm
    input = { n: 5 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
    assert_equal({ n: 5, sign: :positive }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  def test_branch_else_arm_matches_legacy
    workflow = positive_arm | else_arm
    input = { n: -3 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
    assert_equal({ n: -3, sign: :negative }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  def test_branch_no_match_matches_legacy
    workflow = positive_arm # Else 無し: どの arm も match しない
    input = { n: -1 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
    assert_equal :no_branch_matched, effect.code
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 6. Rescue — dual-run 差分検証 (成功スルー / 回復 / 回復も失敗)
  # ================================================================
  def test_rescue_body_success_passes_through_matches_legacy
    workflow = set_a.rescue_with { |_error, focus| focus[:healed].set(true) }
    input = { base: 0 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
    assert_equal({ base: 0, a: 1 }, effect.focus.to_h) # handler は発火しない
    assert_same_envelope(legacy, effect)
  end

  def test_rescue_recovers_body_failure_matches_legacy
    workflow = boom.rescue_with { |_error, focus| focus[:healed].set(true) }
    input = { base: 0 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Ok, effect
    assert_equal({ base: 0, healed: true }, effect.focus.to_h)
    assert_same_envelope(legacy, effect)
  end

  def test_rescue_recovery_failure_matches_legacy
    workflow = boom.rescue_with { |_error, focus| focus.reject(:heal_failed, 'could not heal') }
    input = { base: 0 }

    legacy = workflow.call(Berylx::Focus[input])
    effect = Berylx::EffectTree.run(workflow, input)

    assert_instance_of Berylx::Err, effect
    assert_equal :heal_failed, effect.code
    assert_equal :rescue, effect.failed_node
    assert_same_envelope(legacy, effect)
  end

  # ================================================================
  # 7. dry-run — parallel / branch / rescue も副作用ゼロで計画列挙
  # ================================================================
  def test_dry_run_parallel_enumerates_all_branches_without_executing
    workflow = set_a & boom & set_b # boom は実行されれば raise する

    dry = Berylx::EffectTree.dry_run(workflow, { base: 0 })

    assert_equal %i[set_a boom set_b], dry.steps # 全 branch を列挙
    assert_instance_of Berylx::Ok, dry.result
    assert_equal({ base: 0 }, dry.result.focus.to_h) # 副作用ゼロ
  end

  def test_dry_run_branch_enumerates_matched_arm_only
    workflow = positive_arm | else_arm

    dry = Berylx::EffectTree.dry_run(workflow, { n: 5 })

    assert_equal %i[mark_positive], dry.steps # match した arm のみ
    assert_instance_of Berylx::Ok, dry.result
    assert_equal({ n: 5 }, dry.result.focus.to_h)
  end

  def test_dry_run_rescue_enumerates_body_only
    workflow = boom.rescue_with { |_error, focus| focus[:healed].set(true) }

    dry = Berylx::EffectTree.dry_run(workflow, { base: 0 })

    assert_equal %i[boom], dry.steps # body のみ、handler は発火しない
    assert_instance_of Berylx::Ok, dry.result
    assert_equal({ base: 0 }, dry.result.focus.to_h)
  end
end
