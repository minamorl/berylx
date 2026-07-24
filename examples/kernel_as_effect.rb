# frozen_string_literal: true

# 一つの言語に見えるか — 実行水準の選択を「圏の選択」に合流させる
# ===========================================================================
#
# darkcore の掟は spec でこう書かれている:
#
#     category.selection = handler_map
#     io.representation  = tagged_effect      (IO は不透明サンクではなくデータ)
#     core.algebra.site in [handler, on_return]
#
# moissanite の掟は言葉が違うだけで同じ形をしている:
#
#     カーネルは式木 (不透明サンクではなくデータ)
#     意味は oracle / cc / tcc のどれで解釈するかで決まる
#     算術の algebra が現れるのは interpreter と emitter だけ
#
# **同じ法が二つの高度で二回**書かれている。だからこの二つは「たまたま
# 一緒に使える二つの gem」ではなく、一つの世界観の上下になりうる。
#
# ただし今は継ぎ目が一箇所ずれている。水準の選び方が違うのである:
#
#     darkcore/berylx : handler マップを差し替える  (プログラム内の選択)
#     moissanite      : MOISSANITE_BACKEND を見る   (プロセス外の選択)
#
# 同じ考えが二つの非互換な形で書かれていると、二つの gem に見える。
# しかも実害がある — examples/moissanite_signal_workflow.rb のように
# Task の block の中でカーネルを呼ぶと、**その呼び出しは effect 木から
# 見えない**。berylx 自身の掟 substrate.no_opaque_thunk を、継ぎ目の所で
# 破っていることになる。audit 圏で流しても、算術の一段は木に出てこない。
#
# 直し方は一手で済む。**カーネル呼び出しを tagged effect にする**。
# そうすると:
#
#   - 水準の選択が handler マップに合流する (env var が要らなくなる)
#   - audit 圏がネイティブの一段まで見えるようになる
#   - 「canon 圏と fast 圏で答えが一致すること」という一文が、IO の差分検証と
#     算術の差分検証を**同時に**言うようになる
#
# 走らせ方:  ruby examples/kernel_as_effect.rb
# ===========================================================================

require 'darkcore'
require 'moissanite'

# ---------------------------------------------------------------------------
# 1. 語彙 — 作用は 2 種類しかない。設定を読むことと、カーネルを走らせること。
#    どちらも Darkcore.op が返すただのデータで、ここでは何も起きない。
# ---------------------------------------------------------------------------
READ_RECIPE = :read_recipe
KERNEL      = :moissanite_kernel
EMIT        = :emit

def read_recipe = Darkcore.op(READ_RECIPE)
def emit(report) = Darkcore.op(EMIT, report)

# カーネル呼び出しも作用にする。payload は [カーネル, 引数] という検査可能な
# データで、**カーネル自身が式木**なので payload の中身まで覗ける。
def run_kernel(kernel, *args) = Darkcore.op(KERNEL, [kernel, args])

# ---------------------------------------------------------------------------
# 2. プログラム — レシピは実行時にしか判らないので、カーネルはレシピを
#    読んだ**あと**に組む。係数は定数として機械語へ畳まれる。
#    これが AOT に真似できない所で、ここでは bind の中のただの Ruby である。
# ---------------------------------------------------------------------------
def conditioner(recipe)
  Moissanite::Pipeline.f64
                      .map { |v| (v * recipe.fetch(:gain)) + recipe.fetch(:offset) }
                      .map { |v| v.abs.sqrt }
                      .map { |v| v.min(recipe.fetch(:clip)).max(-recipe.fetch(:clip)) }
end

def program(samples)
  read_recipe.bind do |recipe|
    pipeline = conditioner(recipe)
    count = samples.size
    conditioned = Moissanite::Buffer.f64(count)

    run_kernel(pipeline.fuse(:condition), conditioned, samples, count).bind do
      run_kernel(pipeline.map { |v| v * v }.sum(:energy), samples, count).bind do |energy|
        emit(count: count, rms: Math.sqrt(energy / count), head: conditioned.to_a.first(3))
      end
    end
  end
end

# ---------------------------------------------------------------------------
# 3. 圏 — プログラムは一行も書き換えない。handler マップだけを差し替える。
#    水準 (native / oracle) の選択が、実 IO と記録 IO の選択と**同じ機構**に
#    なっていることが要点。
# ---------------------------------------------------------------------------
RECIPE_ON_DISK = { gain: 1.8, offset: -0.35, clip: 2.5 }.freeze

# 実行圏: 実際に設定を読み、ネイティブで走らせ、実際に出力する。
REAL = {
  READ_RECIPE => ->(_) { RECIPE_ON_DISK },
  KERNEL => ->((kernel, args)) { kernel.call(*args) },
  EMIT => ->(report) { report }
}.freeze

# 正典圏: 同じプログラムを **oracle だけ**で走らせる。C コンパイラに一度も
# 触らない。moissanite の意味論の定義そのもの。
CANON = REAL.merge(KERNEL => ->((kernel, args)) { kernel.interpret(*args) }).freeze

# 監査圏: 何が起きるはずかを列挙する。カーネルは走らせず、**式木を見せる**。
# 木を見せられるのは、カーネルがサンクではなくデータだから。
def audit_category(log)
  {
    READ_RECIPE => lambda { |_|
      log << 'read recipe'
      RECIPE_ON_DISK
    },
    KERNEL => lambda { |(kernel, args)|
      shape = args.map { |a| a.is_a?(Moissanite::Buffer) ? "buf(#{a.size})" : a.inspect }
      log << "kernel #{kernel.name}(#{shape.join(', ')}) -> #{kernel.return_type}"
      log << "  guard: #{kernel.extent_guard ? 'elementwise (parallelizable, bounds-checkable)' : 'none claimed'}"
      log << "  tree:  #{kernel.to_sexp.inspect[0, 96]}..."
      kernel.return_type == :f64 ? 0.0 : 0
    },
    EMIT => lambda { |report|
      log << "emit #{report.keys.inspect}"
      report
    }
  }
end

# ---------------------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
  samples = Moissanite::Buffer.f64(Array.new(50_000) { |i| Math.sin(i / 97.0) * 1.4 })

  real = Darkcore.run(program(samples), REAL)
  canon = Darkcore.run(program(samples), CANON)

  # 例は自分で不変条件を検査する (走らせること自体が検査になる)。
  raise "real と canon が食い違った: #{real.inspect} / #{canon.inspect}" unless real == canon

  puts '== 同じプログラム・違う圏 ================================================='
  puts "real  (native): rms=#{format('%.17g', real[:rms])}"
  puts "canon (oracle): rms=#{format('%.17g', canon[:rms])}"
  puts "一致: #{real == canon}   <- 継ぎ目をまたいだ差分検証が、圏の選択だけで書ける"
  puts

  log = []
  Darkcore.run(program(samples), audit_category(log))
  puts '== 監査圏: ネイティブの一段まで木に出る ==================================='
  puts log.map { |line| "  #{line}" }
  puts
  puts '  (Task の block の中でカーネルを呼んでいた時は、この 3 行は出てこない。'
  puts '   算術は不透明サンクの向こう側にあり、木から見えなかった。)'
end
