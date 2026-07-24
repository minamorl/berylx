# frozen_string_literal: true

# Berylx workflow + moissanite kernels: orchestration and the native level,
# in one Ruby program.
#
# The division of labour is the point:
#
#   Berylx  — names the steps, owns the committed state, keeps failures
#             recoverable, and compiles the whole flow into an inspectable
#             graph. Everything here is a `Task` over a `Lay`.
#   moissanite — does the per-sample arithmetic at native speed. A kernel is an
#             expression tree built out of Ruby values, lowered through the
#             system C compiler and called through Fiddle.
#
# There is no adapter between them and none is needed: a compiled kernel is
# just a callable, so a Task body calls it like any other Ruby object. The
# effect tree stays the linker.
#
#   gem "berylx"
#   gem "moissanite"
#
#   ruby examples/moissanite_signal_workflow.rb

require 'berylx'
require 'moissanite'

# ---------------------------------------------------------------------------
# The processing recipe is configuration — it is not known when this file is
# written, and in a real service it would come from a request or a database
# row. moissanite builds a kernel for *this* recipe at runtime, so the
# coefficients below become constants in the emitted machine code.
# ---------------------------------------------------------------------------
RECIPE = {
  'gain' => 1.8,
  'offset' => -0.35,
  'clip' => 2.5,
  'reject_below' => 0.05
}.freeze

def build_conditioner(recipe)
  Moissanite::Pipeline.f64
                      .map { |v| (v * recipe.fetch('gain')) + recipe.fetch('offset') }
                      .map { |v| v.abs.sqrt }
                      .map { |v| v.min(recipe.fetch('clip')).max(-recipe.fetch('clip')) }
end

def build_rejector(recipe)
  # f64 samples in, i64 flags out — the output element type follows the stages.
  Moissanite::Pipeline.f64.map { |v| Moissanite::Expr.select(v.abs < recipe.fetch('reject_below'), 1, 0) }
end

CONDITIONER = build_conditioner(RECIPE)
REJECTOR = build_rejector(RECIPE)

CONDITION_KERNEL = CONDITIONER.fuse(:condition)
REJECT_KERNEL = REJECTOR.fuse(:reject)
ENERGY_KERNEL = CONDITIONER.map { |v| v * v }.sum(:energy)
REJECTED_COUNT = REJECTOR.sum(:rejected)

# ---------------------------------------------------------------------------
# Tasks. Each one observes the Lay, calls a native kernel, and returns an
# updated Lay. Failures stay inside the Berylx result envelope.
# ---------------------------------------------------------------------------
Validate = Berylx::Task[:validate] do |lay|
  samples = lay[:samples].get
  if !samples.is_a?(Moissanite::Buffer) || samples.size.zero?
    lay.reject(:empty_signal, 'expected a non-empty Moissanite::Buffer of samples')
  else
    lay[:count].set(samples.size)
  end
end

# The conditioning pipeline was assembled from RECIPE at load time and fused
# into a single pass. `call_parallel` splits it across cores; the split is
# safe because the kernel is provably elementwise (moissanite's extent guard).
Condition = Berylx::Task[:condition] do |lay|
  samples = lay[:samples].get
  count = lay[:count].get
  conditioned = Moissanite::Buffer.f64(count)
  CONDITION_KERNEL.call_parallel(conditioned, samples, count)
  lay[:conditioned].set(conditioned)
end

Reject = Berylx::Task[:reject] do |lay|
  samples = lay[:samples].get
  count = lay[:count].get
  flags = Moissanite::Buffer.i64(count)
  REJECT_KERNEL.call(flags, samples, count)
  rejected = REJECTED_COUNT.call(samples, count)
  lay[:flags].set(flags)[:rejected].set(rejected)
end

# A fused map-reduce: no intermediate buffer is allocated at all.
Measure = Berylx::Task[:measure] do |lay|
  samples = lay[:samples].get
  count = lay[:count].get
  energy = ENERGY_KERNEL.call(samples, count)
  lay[:energy].set(energy)[:rms].set(Math.sqrt(energy / count))
end

# Summarize also runs on the recovered path, where the earlier tasks never
# set their fields — so it reads with `maybe` rather than assuming success.
Summarize = Berylx::Task[:summarize] do |lay|
  rms = lay[:rms].maybe
  lay[:report].set(
    count: lay[:count].maybe,
    rejected: lay[:rejected].maybe,
    rms: rms&.round(6),
    failure: lay[:failure].maybe,
    backend: CONDITION_KERNEL.backend_name
  )
end

# Failures keep the partial Lay, so compensation can see how far we got.
WORKFLOW =
  Validate >>
  Condition >>
  Reject >>
  Measure >>
  Berylx::Catch[:record_failure] { |error, lay| lay[:failure].set(error.message) } >>
  Summarize

# ---------------------------------------------------------------------------
# Run it.
# ---------------------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
  samples = Moissanite::Buffer.f64(Array.new(200_000) { |i| Math.sin(i / 97.0) * 1.4 })

  root = Berylx::Root[samples: samples]
  result = root | WORKFLOW

  puts "result: #{result.class}"
  puts "report: #{result.focus[:report].get}"
  puts
  puts 'graph:'
  puts WORKFLOW.compile.to_dot

  # The empty-signal path: Validate rejects, later tasks short-circuit, and
  # Catch turns the failure into a recorded field instead of an exception.
  empty = Berylx::Root[samples: nil]
  recovered = empty | WORKFLOW
  puts
  puts "empty signal -> #{recovered.class}"
  puts "report:       #{recovered.focus[:report].get}"
end
