# frozen_string_literal: true

require "minitest/autorun"
require "beryl"

class BerylTest < Minitest::Test
  def test_compose
    add = Beryl::Fn[&->(value) { value + 1 }]
    mul = Beryl::Fn[&->(value) { value * 2 }]

    assert_equal 22, (add >> mul).call(10)
  end

  def test_result_map
    result = Beryl::Result.map(Beryl::Result.ok(10)) { _1 + 1 }

    assert_equal Beryl::Ok.new(11), result
  end

  def test_task_sequence_over_focus
    strip = Beryl::Task[:strip] { |root| root[:name].update(&:strip) }
    greet = Beryl::Task[:greet] { |root| root[:greeting].set("hello #{root[:name].get}") }

    result = (strip >> greet).call(Beryl::Focus[name: "  mina  "])

    assert_instance_of Beryl::Ok, result
    assert_equal({ name: "mina", greeting: "hello mina" }, result.focus.to_h)
  end

  def test_parallel_runs_branches_against_snapshot_and_reduces
    left = Beryl::Task[:left] do |root|
      sleep 0.1
      root[:left].set(root[:base].get + 1)
    end
    right = Beryl::Task[:right] do |root|
      sleep 0.1
      root[:right].set(root[:base].get + 2)
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = (left & right).reduce(Beryl::Merge.deep).call(Beryl::Focus[base: 10])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_instance_of Beryl::Ok, result
    assert_operator elapsed, :<, 0.18
    assert_equal({ base: 10, left: 11, right: 12 }, result.focus.to_h)
  end

  def test_branch_when_else_syntax
    paid = Beryl::Task[:paid] { |root| root[:status].set(:paid) }
    trial = Beryl::Task[:trial] { |root| root[:status].set(:trial) }

    branch =
      (Beryl::When[:paid] { |root| root[:plan].get == :paid } >> paid) |
      (Beryl::Else >> trial)

    paid_result = branch.call(Beryl::Focus[plan: :paid])
    trial_result = branch.call(Beryl::Focus[plan: :free])

    assert_equal :paid, paid_result.focus[:status].get
    assert_equal :trial, trial_result.focus[:status].get
  end

  def test_rescue_with_task_keeps_partial_focus
    charge = Beryl::Task[:charge] { |root| root[:charged].set(true) }
    explode = Beryl::Task[:explode] { |_root| raise "stripe timeout" }
    compensate = Beryl::Task[:compensate] do |root|
      root[:compensated].set(root[:charged].get)
    end

    result = (charge >> explode).rescue_with(compensate).call(Beryl::Focus[])

    assert_instance_of Beryl::Ok, result
    assert_equal({ charged: true, compensated: true }, result.focus.to_h)
  end

  def test_rescue_with_block_can_return_err_or_focus
    explode = Beryl::Task[:explode] { |_root| raise "boom" }

    result = explode.rescue_with(:mark_failed) do |error, root|
      root[:error].set(error.message)
    end.call(Beryl::Focus[])

    assert_instance_of Beryl::Ok, result
    assert_equal({ error: "boom" }, result.focus.to_h)
  end

  def test_workflow_compile_exposes_nodes_parallel_and_branches
    a = Beryl::Task[:a] { _1 }
    b = Beryl::Task[:b] { _1 }
    c = Beryl::Task[:c] { _1 }
    fallback = Beryl::Task[:fallback] { _1 }

    workflow = Beryl::Workflow[:example] do
      (a & b).reduce(Beryl::Merge.deep) >>
        ((Beryl::When[:ok] { true } >> c) | (Beryl::Else >> fallback))
    end

    graph = workflow.compile

    assert_equal %i[a b c fallback], graph.nodes
    assert_equal [%i[a b]], graph.parallel_nodes
    assert_equal :example, graph.name
    assert_includes graph.to_dot, "example"
  end
end
