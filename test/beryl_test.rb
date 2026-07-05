# frozen_string_literal: true

require 'minitest/autorun'
require 'beryl'

class BerylTest < Minitest::Test
  def test_result_map
    result = Beryl::Result.map(Beryl::Result.ok(10)) { _1 + 1 }

    assert_equal Beryl::Ok.new(10), Beryl::Result.ok(10)
    assert_equal Beryl::Ok.new(11), result
  end

  def test_flow_starts_from_lay_focus
    flow = Beryl::Flow[Beryl::Lay[name: '  mina  ']]

    assert_instance_of Beryl::Flow, flow
    assert_equal({ name: '  mina  ' }, flow.focus.to_h)
  end

  def test_flow_call_runs_node_from_its_lay_origin
    strip = Beryl::Task[:strip] { |root| root[:name].update(&:strip) }
    greet = Beryl::Task[:greet] { |root| root[:greeting].set("hello #{root[:name].get}") }

    result = Beryl::Flow[Beryl::Lay[name: '  mina  ']].call(strip >> greet)

    assert_instance_of Beryl::Ok, result
    assert_equal({ name: 'mina', greeting: 'hello mina' }, result.focus.to_h)
  end

  def test_state_pipe_task_syntax_lifts_lay_into_state_space
    state = Beryl::State[name: '  mina  ']
    strip = Beryl.task(:strip) { |lay| lay[:name].update(&:strip) }
    greet = Beryl.task(:greet) { |lay| lay[:greeting].set("hello #{lay[:name].get}") }

    result = state | strip | greet

    assert_instance_of Beryl::Ok, result
    assert_equal({ name: 'mina', greeting: 'hello mina' }, result.focus.to_h)
  end

  def test_task_sequence_over_lay_focus
    strip = Beryl::Task[:strip] { |root| root[:name].update(&:strip) }
    greet = Beryl::Task[:greet] { |root| root[:greeting].set("hello #{root[:name].get}") }

    result = (strip >> greet).call(Beryl::Lay[name: '  mina  '])

    assert_instance_of Beryl::Ok, result
    assert_equal({ name: 'mina', greeting: 'hello mina' }, result.focus.to_h)
  end

  def test_root_is_common_origin_for_lay_and_state_layers
    strip = Beryl.task(:strip) { |lay| lay[:name].update(&:strip) }
    greet = Beryl.task(:greet) { |lay| lay[:greeting].set("hello #{lay[:name].get}") }

    root = Beryl::Root[name: '  mina  ']

    lay_result = (strip >> greet).call(root.to_lay)
    state_result = root | strip | greet

    assert_equal({ name: 'mina', greeting: 'hello mina' }, lay_result.focus.to_h)
    assert_equal lay_result.focus.to_h, state_result.focus.to_h
  end

  def test_err_unwrap_maps_back_to_plain_ruby_exception
    cause = RuntimeError.new('stripe timeout')
    result = Beryl::Result.err(Beryl::Lay[charged: true], :payment_failed, 'payment failed', cause: cause)

    assert_same cause, result.to_exception
    error = assert_raises(RuntimeError) { result.unwrap }
    assert_same cause, error
  end

  def test_root_commits_task_results_back_to_the_same_entity
    root = Beryl::Root[request: { id: 'req_1' }, checkout: { user_id: 1 }]
    enrich = Beryl.task(:enrich) { |lay| lay[:checkout][:plan_id].set(3) }

    result = root | enrich

    assert_instance_of Beryl::Ok, result
    assert_equal({ request: { id: 'req_1' }, checkout: { user_id: 1, plan_id: 3 } }, result.focus.to_h)
    assert_equal result.focus.to_h, root.state
  end

  def test_root_does_not_commit_err_results_automatically
    root = Beryl::Root[charged: false]
    fail_after_charge = Beryl.task(:fail_after_charge) do |lay|
      lay[:charged].set(true).reject(:payment_failed, 'payment failed')
    end

    result = root | fail_after_charge

    assert_instance_of Beryl::Err, result
    assert_equal({ charged: true }, result.focus.to_h)
    assert_equal({ charged: false }, root.state)
  end

  def test_root_commit_deep_merges_external_observations
    root = Beryl::Root[user: { id: 1, name: 'mina' }]

    root.commit(user: { role: 'admin' })

    assert_equal({ user: { id: 1, name: 'mina', role: 'admin' } }, root.state)
  end

  def test_root_subscribe_observes_snapshot_and_commits
    root = Beryl::Root[count: 0]
    events = []
    root.subscribe { events << _1 }

    root.commit(count: 1)

    assert_equal({ type: :snapshot, value: { count: 0 } }, events.first)
    assert_equal({ type: :commit, value: { count: 1 } }, events.last)
  end

  def test_focus_lookup_helpers_make_missing_paths_explicit
    focus = Beryl::Lay[user: { name: 'mina' }]

    assert_equal 'mina', focus[:user][:name].get
    assert_nil focus[:missing].maybe
    assert_equal :fallback, focus[:missing].fetch(:fallback)
    refute_predicate focus[:missing], :present?

    result = focus[:missing].required(:missing_user)

    assert_instance_of Beryl::Err, result
    assert_equal :missing_user, result.code

    present = focus[:user].required(:missing_user)

    assert_instance_of Beryl::Ok, present
    assert_equal({ name: 'mina' }, present.focus.get)
  end

  def test_domain_err_unwrap_raises_beryl_error_when_no_plain_cause_exists
    result = Beryl::Lay[].reject(:duplicate_subscription, 'already subscribed')

    error = assert_raises(Beryl::Error) { result.unwrap }
    assert_equal :duplicate_subscription, error.code
    assert_equal 'already subscribed', error.message
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
    result = Beryl::Flow[Beryl::Lay[base: 10]].call((left & right).reduce(Beryl::Merge.deep))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_instance_of Beryl::Ok, result
    assert_operator elapsed, :<, 0.18
    assert_equal({ base: 10, left: 11, right: 12 }, result.focus.to_h)
  end

  def test_strict_parallel_merge_allows_independent_updates
    left = Beryl::Task[:left] { |root| root[:left].set(1) }
    right = Beryl::Task[:right] { |root| root[:right].set(2) }

    result = Beryl::Flow[Beryl::Lay[base: 10]].call((left & right).reduce(Beryl::Merge.strict))

    assert_instance_of Beryl::Ok, result
    assert_equal({ base: 10, left: 1, right: 2 }, result.focus.to_h)
  end

  def test_strict_parallel_merge_rejects_conflicting_updates
    left = Beryl::Task[:left] { |root| root[:status].set(:paid) }
    right = Beryl::Task[:right] { |root| root[:status].set(:trial) }

    result = Beryl::Flow[Beryl::Lay[status: nil]].call((left & right).reduce(Beryl::Merge.strict))

    assert_instance_of Beryl::Err, result
    assert_equal :merge_conflict, result.code
    assert_equal :parallel, result.failed_node
    assert_equal({ status: nil }, result.focus.to_h)
  end

  def test_branch_when_else_syntax
    paid = Beryl::Task[:paid] { |root| root[:status].set(:paid) }
    trial = Beryl::Task[:trial] { |root| root[:status].set(:trial) }

    branch =
      (Beryl::When[:paid] { |root| root[:plan].get == :paid } >> paid) |
      (Beryl::Else >> trial)

    paid_result = Beryl::Flow[Beryl::Lay[plan: :paid]].call(branch)
    trial_result = Beryl::Flow[Beryl::Lay[plan: :free]].call(branch)

    assert_equal :paid, paid_result.focus[:status].get
    assert_equal :trial, trial_result.focus[:status].get
  end

  def test_rescue_with_task_keeps_partial_focus
    charge = Beryl::Task[:charge] { |root| root[:charged].set(true) }
    explode = Beryl::Task[:explode] { |_root| raise 'stripe timeout' }
    compensate = Beryl::Task[:compensate] do |root|
      root[:compensated].set(root[:charged].get)
    end

    result = Beryl::Flow[Beryl::Lay[]].call((charge >> explode).rescue_with(compensate))

    assert_instance_of Beryl::Ok, result
    assert_equal({ charged: true, compensated: true }, result.focus.to_h)
  end

  def test_catch_boundary_recovers_previous_sequence_failure_and_continues
    charge = Beryl::Task[:charge] { |root| root[:charged].set(true) }
    explode = Beryl::Task[:explode] { |_root| raise 'stripe timeout' }
    notify = Beryl::Task[:notify] { |root| root[:notified].set(true) }

    result = Beryl::Flow[Beryl::Lay[]].call(
      charge >> explode >>
        Beryl::Catch[:refund] { |error, root| root[:refunded].set(error.message) } >>
        notify
    )

    assert_instance_of Beryl::Ok, result
    assert_equal({ charged: true, refunded: 'stripe timeout', notified: true }, result.focus.to_h)
  end

  def test_catch_boundary_is_ignored_when_sequence_is_successful
    charge = Beryl::Task[:charge] { |root| root[:charged].set(true) }
    notify = Beryl::Task[:notify] { |root| root[:notified].set(true) }

    result = Beryl::Flow[Beryl::Lay[]].call(
      charge >>
        Beryl::Catch[:refund] { |_error, root| root[:refunded].set(true) } >>
        notify
    )

    assert_instance_of Beryl::Ok, result
    assert_equal({ charged: true, notified: true }, result.focus.to_h)
  end

  def test_task_exception_returns_defined_error_with_failed_node_and_trace
    charge = Beryl::Task[:charge] { |root| root[:charged].set(true) }
    explode = Beryl::Task[:explode] { |_root| raise 'stripe timeout' }

    result = Beryl::Flow[Beryl::Lay[]].call(charge >> explode)

    assert_instance_of Beryl::Err, result
    assert_instance_of Beryl::Error, result.error
    assert_equal :RuntimeError, result.code
    assert_equal 'stripe timeout', result.message
    assert_equal :explode, result.failed_node
    assert_equal %i[explode], result.trace
    assert_equal({ charged: true }, result.focus.to_h)
  end

  def test_lay_reject_returns_defined_error
    reject = Beryl::Task[:reject_duplicate] do |root|
      root[:checked].set(true).reject(:duplicate_subscription, 'already subscribed')
    end

    result = Beryl::Flow[Beryl::Lay[]].call(reject)

    assert_instance_of Beryl::Err, result
    assert_equal :duplicate_subscription, result.code
    assert_equal 'already subscribed', result.message
    assert_equal :reject_duplicate, result.failed_node
    assert_equal %i[reject_duplicate], result.trace
    assert_equal({ checked: true }, result.focus.to_h)
  end

  def test_parallel_collects_multiple_branch_errors
    left = Beryl::Task[:left] { |_root| raise 'left failed' }
    right = Beryl::Task[:right] { |_root| raise 'right failed' }

    result = Beryl::Flow[Beryl::Lay[]].call((left & right).accumulate)

    assert_instance_of Beryl::Err, result
    assert_equal :parallel_failed, result.code
    assert_equal 2, result.parallel_errors.size
    assert_equal %i[left right], result.parallel_errors.map(&:failed_node)
  end

  def test_parallel_short_circuit_is_default
    left = Beryl::Task[:left] { |_root| raise 'left failed' }
    right = Beryl::Task[:right] { |_root| raise 'right failed' }

    result = Beryl::Flow[Beryl::Lay[]].call(left & right)

    assert_instance_of Beryl::Err, result
    refute_equal :parallel_failed, result.code
    assert_equal :RuntimeError, result.code
    assert_equal :left, result.failed_node
    assert_empty result.parallel_errors
  end

  def test_parallel_accumulate_collects_all
    left = Beryl::Task[:left] { |_root| raise 'left failed' }
    right = Beryl::Task[:right] { |_root| raise 'right failed' }

    result = Beryl::Flow[Beryl::Lay[]].call((left & right).accumulate)

    assert_instance_of Beryl::Err, result
    assert_equal :parallel_failed, result.code
    assert_equal 2, result.parallel_errors.size
    assert_equal %i[left right], result.parallel_errors.map(&:failed_node)
  end

  def test_parallel_short_circuit_success_still_merges
    left = Beryl::Task[:left] { |root| root[:left].set(1) }
    right = Beryl::Task[:right] { |root| root[:right].set(2) }

    result = Beryl::Flow[Beryl::Lay[base: 10]].call((left & right).reduce(Beryl::Merge.deep))

    assert_instance_of Beryl::Ok, result
    assert_equal({ base: 10, left: 1, right: 2 }, result.focus.to_h)
  end

  def test_parallel_mode_preserved_through_reduce_and_and
    left = Beryl::Task[:left] { |_root| raise 'left failed' }
    right = Beryl::Task[:right] { |_root| raise 'right failed' }
    third = Beryl::Task[:third] { |_root| raise 'third failed' }

    combined = ((left & right).accumulate.reduce(Beryl::Merge.deep) & third)
    result = Beryl::Flow[Beryl::Lay[]].call(combined)

    assert_instance_of Beryl::Err, result
    assert_equal :accumulate, combined.on_err
    assert_equal :parallel_failed, result.code
    assert_equal 3, result.parallel_errors.size
    assert_equal %i[left right third], result.parallel_errors.map(&:failed_node)
  end

  def test_rescue_with_block_can_return_err_or_focus
    explode = Beryl::Task[:explode] { |_root| raise 'boom' }

    result = Beryl::Flow[Beryl::Lay[]].call(
      explode.rescue_with(:mark_failed) do |error, root|
        root[:error].set(error.message)
      end
    )

    assert_instance_of Beryl::Ok, result
    assert_equal({ error: 'boom' }, result.focus.to_h)
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
    assert_includes graph.to_dot, 'example'
  end

  def test_to_dot_sequence_chains_nodes_with_edges
    a = Beryl::Task[:a] { _1 }
    b = Beryl::Task[:b] { _1 }
    c = Beryl::Task[:c] { _1 }

    dot = (a >> b >> c).compile.to_dot

    assert_includes dot, '"a#0";'
    assert_includes dot, '"b#1";'
    assert_includes dot, '"c#2";'
    assert_includes dot, '"a#0" -> "b#1";'
    assert_includes dot, '"b#1" -> "c#2";'
  end

  def test_to_dot_parallel_fans_out_and_in
    a = Beryl::Task[:a] { _1 }
    b = Beryl::Task[:b] { _1 }

    dot = (a & b).compile.to_dot

    assert_includes dot, '"split#0";'
    assert_includes dot, '"join#1";'
    assert_includes dot, '"split#0" -> "a#2";'
    assert_includes dot, '"a#2" -> "join#1";'
    assert_includes dot, '"split#0" -> "b#3";'
    assert_includes dot, '"b#3" -> "join#1";'
  end

  def test_to_dot_branch_labels_each_arm
    c = Beryl::Task[:c] { _1 }
    fallback = Beryl::Task[:fallback] { _1 }

    branch = (Beryl::When[:ok] { true } >> c) | (Beryl::Else >> fallback)
    dot = Beryl::Graph.from(branch).to_dot

    assert_includes dot, '"branch#0";'
    assert_includes dot, '"branch#0" -> "c#1" [label="ok"];'
    assert_includes dot, '"branch#0" -> "fallback#2" [label="else"];'
  end
end
