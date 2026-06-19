# frozen_string_literal: true

require_relative 'beryl/version'
require_relative 'beryl/fn'
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
require_relative 'beryl/prelude'

module Beryl
  Lay = Focus

  def self.run(workflow, focus)
    Flow[focus].call(workflow)
  end
end
