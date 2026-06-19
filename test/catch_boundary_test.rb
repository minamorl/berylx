# frozen_string_literal: true

require 'minitest/autorun'
require 'beryl'

class CatchBoundaryTest < Minitest::Test
  TERMINAL_KEY = :fatal

  def test_catch_does_not_handle_terminal_errors_by_default
    stop = Beryl::Task[:stop] do |root|
      Beryl::Result.err(root[:stopped].set(true), :stop, 'stop', **{ TERMINAL_KEY => true })
    end
    recover = Beryl::Task[:recover] { |root| root[:recovered].set(true) }

    result = Beryl::Flow[Beryl::Lay[]].call(
      stop >>
        Beryl::Catch[:recover] { |_error, root| root[:caught].set(true) } >>
        recover
    )

    assert_instance_of Beryl::Err, result
    assert_equal :stop, result.code
    assert_predicate result.error, :fatal?
    assert_equal({ stopped: true }, result.focus.to_h)
  end

  def test_catch_can_opt_into_terminal_errors
    stop = Beryl::Task[:stop] do |root|
      Beryl::Result.err(root[:stopped].set(true), :stop, 'stop', **{ TERMINAL_KEY => true })
    end
    recover = Beryl::Task[:recover] { |root| root[:recovered].set(true) }

    result = Beryl::Flow[Beryl::Lay[]].call(
      stop >>
        Beryl::Catch[:recover, **{ TERMINAL_KEY => true }] { |error, root| root[:caught].set(error.message) } >>
        recover
    )

    assert_instance_of Beryl::Ok, result
    assert_equal({ stopped: true, caught: 'stop', recovered: true }, result.focus.to_h)
  end
end
