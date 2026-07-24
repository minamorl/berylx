# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# native bridge (C interpreter) と pure Ruby fold の構造的等価性を、
# 全合成子・全失敗経路で差分検証する。
#
# - native 側は EffectTree::Native.run_entry を直接呼ぶ (gate や
#   BERYLX_NATIVE の状態に依存しない)。
# - pure Ruby 側は handler マップを dup して渡すことで native gate を
#   外し、必ず Darkcore.fold 経路を走らせる (lambda は同一なので挙動は
#   既定 real 圏そのもの)。
# - 封筒は canonicalize して比較する (Error は to_h + cause class、
#   Focus は path + value。Error#== は同一性比較なので構造で比べる)。
class NativeEquivalenceTest < Minitest::Test
  def setup
    skip 'berylx_native is not compiled' unless Berylx::EffectTree::Native.available?
  end

  def task(name, &block)
    Berylx::Task[name, &block]
  end

  def canon(value)
    case value
    when Berylx::Ok then { k: :ok, focus: canon_focus(value.focus) }
    when Berylx::Err then { k: :err, focus: canon_focus(value.focus), error: canon_error(value.error) }
    else { k: value.class.name, v: value.inspect }
    end
  end

  def canon_focus(focus)
    focus.is_a?(Berylx::Focus) ? { path: focus.path, value: focus.value } : { raw: focus }
  end

  def canon_error(error)
    error.to_h.merge(
      cause_class: error.cause&.class&.name,
      parallel_errors: error.parallel_errors.map { |e| e.respond_to?(:to_h) ? e.to_h : e.to_s }
    )
  end

  # 同じ workflow 生成ブロックから 2 本組み立て (probe を共有しないため)、
  # native / pure Ruby の両経路で走らせて canonical 形を突き合わせる。
  def assert_equivalent(focus_value = {})
    native = Berylx::EffectTree::Native.run_entry(yield, Berylx::Focus[focus_value])
    ruby = Berylx::EffectTree.run(yield, Berylx::Focus[focus_value],
                                  handlers: Berylx::EffectTree.real_handlers.dup)

    assert_equal canon(ruby), canon(native)
    native
  end

  def test_identity_chain
    result = assert_equivalent(x: 1) { task(:a) { |l| l } >> task(:b) { |l| l } >> task(:c) { |l| l } }
    assert_instance_of Berylx::Ok, result
  end

  def test_counter_chain_of_one_thousand
    result = assert_equivalent(count: 0) do
      (1..1000).map { |i| task(:"c#{i}") { |l| l[:count].update { _1 + 1 } } }.reduce(:>>)
    end
    assert_equal 1000, result.focus.to_h[:count]
  end

  def test_empty_sequence
    assert_equivalent(z: 1) { Berylx::Sequence.new([]) }
  end

  def test_short_circuit_skips_later_tasks
    probes = []
    result = assert_equivalent do
      probe = []
      probes << probe
      task(:t1) do |l|
        probe << 1
        l
      end >>
        task(:t2) { |l| l.reject(:boom, 'kaboom') } >>
        task(:t3) do |l|
          probe << 3
          l
        end
    end
    assert_instance_of Berylx::Err, result
    assert_equal [[1], [1]], probes
  end

  def test_task_raising_exception
    assert_equivalent { task(:raiser) { |_l| raise ArgumentError, 'bad arg' } }
  end

  def test_catch_recovers_and_continues
    assert_equivalent do
      task(:f1) { |l| l.reject(:oops, 'x') } >>
        Berylx::Catch[:heal] { |err, l| l.put(:healed, err.code) } >>
        task(:after) { |l| l.put(:after, true) }
    end
  end

  def test_catch_passthrough_on_ok
    calls = []
    assert_equivalent do
      call_probe = []
      calls << call_probe
      task(:okstep) { |l| l } >>
        Berylx::Catch[:nope] do |_e, l|
          call_probe << 1
          l
        end >>
        task(:tail) { |l| l.put(:t, 1) }
    end
    assert_equal [[], []], calls
  end

  def test_fatal_error_skips_catch
    assert_equivalent do
      task(:fat) { |l| Berylx::Result.err(l, Berylx::Error[:dead, 'gone', fatal: true]) } >>
        Berylx::Catch[:heal] { |_e, l| l.put(:h, 1) }
    end
  end

  def test_catch_fatal_true_catches_fatal
    assert_equivalent do
      task(:fat) { |l| Berylx::Result.err(l, Berylx::Error[:dead, 'gone', fatal: true]) } >>
        Berylx::Catch[:heal, fatal: true] { |_e, l| l.put(:h, 1) }
    end
  end

  def test_catch_handler_error_gets_rescue_context
    assert_equivalent do
      task(:f) { |l| l.reject(:a, 'a') } >> Berylx::Catch[:badheal] { |_e, _l| raise 'heal failed' }
    end
  end

  def test_rescue_with_block_recovery
    assert_equivalent do
      task(:f) { |l| l.reject(:r1, 'm1') }.rescue_with { |err, l| l.put(:rescued, err.message) }
    end
  end

  def test_rescue_handler_failure_keeps_original_error_metadata
    assert_equivalent do
      handler = task(:handler) { |l| l.reject(:r2, 'm2') }
      task(:f) { |l| l.reject(:r1, 'm1') }.rescue_with(handler)
    end
  end

  def test_branch_else_taken
    assert_equivalent(x: 1) { branch_workflow }
  end

  def test_branch_predicate_match
    assert_equivalent(x: 11) { branch_workflow }
  end

  def test_branch_no_match_errs
    assert_equivalent do
      pred = Berylx::Predicate.new(:never, ->(_l) { false }, false)
      Berylx::Branch.new([Berylx::BranchArm.new(pred, task(:x) { |l| l })])
    end
  end

  def test_branch_predicate_exception_propagates_in_both
    wf = -> { Berylx::When[:explode] { |_l| raise 'pred boom' } >> task(:x) { |l| l } }
    assert_raises(RuntimeError) { Berylx::EffectTree::Native.run_entry(wf.call, Berylx::Focus[{}]) }
    assert_raises(RuntimeError) do
      Berylx::EffectTree.run(wf.call, Berylx::Focus[{}], handlers: Berylx::EffectTree.real_handlers.dup)
    end
  end

  def test_parallel_merge_ok
    assert_equivalent(base: 0) { task(:pa) { |l| l.put(:a, 1) } & task(:pb) { |l| l.put(:b, 2) } }
  end

  def test_parallel_custom_arity3_reducer
    assert_equivalent(base: 0) do
      reducer = ->(left, right, base) { Berylx::Merge.deep.call(left, right).put(:base_seen, base.to_h.key?(:base)) }
      Berylx::Parallel.new([task(:pa) { |l| l.put(:a, 1) }, task(:pb) { |l| l.put(:b, 2) }], reducer)
    end
  end

  def test_parallel_short_circuit_takes_first_branch_error
    assert_equivalent do
      task(:p1) { |l| l.reject(:e1, 'first') } & task(:p2) { |l| l.reject(:e2, 'second') }
    end
  end

  def test_parallel_accumulate_collects_all_errors
    assert_equivalent do
      (task(:p1) { |l| l.reject(:e1, 'first') } &
        task(:p2) { |l| l.reject(:e2, 'second') } &
        task(:p3) { |l| l.put(:ok3, true) }).accumulate
    end
  end

  def test_parallel_reducer_exception_becomes_err
    assert_equivalent do
      Berylx::Parallel.new([task(:pa) { |l| l }, task(:pb) { |l| l }], ->(_l, _r) { raise 'merge boom' })
    end
  end

  def test_nested_rescue_sequence_parallel
    assert_equivalent do
      inner = (task(:pa) { |l| l.put(:a, 1) } & task(:pb) { |l| l.reject(:pb_bad, 'nope') }) >>
              task(:tail) { |l| l.put(:t, 1) }
      inner.rescue_with { |err, l| l.put(:saved, err.code) }
    end
  end

  def test_bare_value_return_is_normalized
    assert_equivalent(orig: 1) do
      task(:raw) { |_l| { replaced: true } } >> task(:then) { |l| l.put(:seen, l[:replaced].get) }
    end
  end

  def test_late_catch_after_skipped_tasks
    probes = []
    assert_equivalent do
      probe = []
      probes << probe
      task(:f) { |l| l.reject(:e, 'x') } >>
        task(:skipped) do |l|
          probe << 1
          l
        end >>
        Berylx::Catch[:late] { |_e, l| l.put(:late, true) } >>
        task(:after) { |l| l.put(:done, true) }
    end
    assert_equal [[], []], probes
  end

  def test_standalone_catch_returns_ok
    assert_equivalent(z: 9) { Berylx::Catch[:c] { |_e, l| l } }
  end

  def test_deep_sequence_3000_stays_iterative
    result = assert_equivalent(ok: true) do
      (1..3000).map { |i| task(:"d#{i}") { |l| l } }.reduce(:>>)
    end
    assert_instance_of Berylx::Ok, result
  end

  def test_nested_rescue_depth_of_two_hundred
    assert_equivalent(n: 0) do
      node = task(:core) { |l| l[:n].update { _1 + 1 } }
      200.times { node = Berylx::Rescue.new(node, task(:h) { |l| l }) }
      node
    end
  end

  private

  def branch_workflow
    (Berylx::When[:big] { |l| l[:x].get > 10 } >> task(:big) { |l| l.put(:r, :big) }) |
      (Berylx::Else >> task(:small) { |l| l.put(:r, :small) })
  end
end
