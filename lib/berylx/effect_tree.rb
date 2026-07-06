# frozen_string_literal: true

require 'darkcore'

module Berylx
  # ==================================================================
  # Berylx::EffectTree — berylx workflow を darkcore の単一 Effect 型
  # (Freer monad, tagged effect の木) へ載せ替える adapter。
  #
  # 第一段: Sequence(>>) の写像。
  # 第二段: parallel(&) / branch / rescue も同じ Effect 木へ載せる。
  #   合成子はそれぞれ 1 つの tagged effect ノードで表し、モード
  #   (short_circuit / accumulate など) は handler の分岐ではなく
  #   payload に載せた berylx ノード (検査可能データ) から読む。
  #
  # 掟 (spec-system pins) との対応:
  #   - substrate.effect_tree      : workflow を darkcore Effect 木へ写す。
  #   - substrate.task_as_effect   : Task を tagged effect ノード
  #       Effect(:berylx_task, [task, focus], k) として表す。
  #   - substrate.parallel.mapped  : parallel を Effect(:berylx_parallel, [node, focus])
  #       へ写す。short_circuit / accumulate は handler ではなく payload の
  #       node.on_err (タグ) で運ぶ。
  #   - substrate.branch.mapped    : branch を Effect(:berylx_branch, [node, focus])
  #       へ写す。arm の選択は handler の分岐でなく effect 木の tag で表す。
  #   - substrate.rescue.mapped    : rescue を Effect(:berylx_rescue, [node, focus])
  #       へ写す。body の Err は handler 差し替え (回復 handler) で回復させる。
  #   - result.parallel_default    : short_circuit が既定、accumulate はタグ上書き。
  #   - substrate.no_opaque_thunk  : payload は検査可能なデータ (berylx ノード + Focus)。
  #       Task の block や branch/reducer は handler が呼ぶまで実行しない。
  #   - substrate.aspect_via_handler: retry/dry_run/audit は workflow 本体
  #       (compile 結果の Effect 木) を書き換えず handler マップ差し替えで後付け。
  #   - result.envelope            : 成功 Berylx::Ok(lay) / 失敗 Berylx::Err(partial_lay, error)。
  #   - result.sequence_short_circuit: 最初の Err で短絡 (darkcore bind の上に載せる)。
  #   - namespace.separate         : darkcore の bind は必ず bind と呼ぶ。
  #       berylx の >> は berylx の合成子として残す (ここでは演算子を作らない)。
  #
  # darkcore 側の掟: bind は構造の接ぎ木のみ (演算ゼロ)。圏の algebra が
  # 現れるのは handler と on_return だけ。ここでの短絡判定 (Err かどうか) は
  # berylx の Result 圏の algebra なので、darkcore の bind に埋めず、berylx 側の
  # 継続 (bind に渡す関数) の中で行う。
  # ==================================================================
  module EffectTree
    # berylx 合成子を darkcore Effect 木にディスパッチするためのタグ。
    TASK     = :berylx_task
    PARALLEL = :berylx_parallel
    BRANCH   = :berylx_branch
    RESCUE   = :berylx_rescue

    # dry_run の戻り値: 最終結果 (実行しないので常に Ok) と、列挙された計画。
    DryRun = Data.define(:result, :steps)

    module_function

    # ----------------------------------------------------------------
    # compile — berylx ノードを「Focus を受け取り darkcore Effect を返す」
    # Kleisli 矢に落とす。
    #   Sequence は bind で接ぎ木し (compile_sequence)、
    #   Task / Parallel / Branch / Rescue はそれぞれ 1 つの tagged effect
    #   ノードに落とす。payload は [node, focus] の検査可能データ
    #   (不透明サンクにしない = substrate.no_opaque_thunk)。
    #   合成子の内部 (branches / arms / body / reducer / on_err) は
    #   handler が副木として実行するまで発火しない。
    # ----------------------------------------------------------------
    def compile(node)
      case node
      when Sequence then compile_sequence(node)
      when Task     then ->(focus) { Darkcore.op(TASK, [node, focus]) }
      when Parallel then ->(focus) { Darkcore.op(PARALLEL, [node, focus]) }
      when Branch   then ->(focus) { Darkcore.op(BRANCH, [node, focus]) }
      when Rescue   then ->(focus) { Darkcore.op(RESCUE, [node, focus]) }
      when Catch    then ->(focus) { Darkcore.pure(Result.ok(focus)) }
      else
        raise ArgumentError,
              "EffectTree supports Task / Sequence / Parallel / Branch / Rescue / Catch, got #{node.class}"
      end
    end

    # Sequence を darkcore bind で接ぎ木する。bind は構造の接ぎ木のみで、
    # 短絡 (Err) 判定・Catch 境界での回復は継続内 = berylx 圏の algebra site で
    # 行う (darkcore の bind には埋めない)。
    def compile_sequence(node)
      lambda do |focus|
        node.steps.reduce(Darkcore.pure(Result.ok(focus))) do |effect, step|
          effect.bind { |prev| compile_step(step, prev) }
        end
      end
    end

    # Sequence の 1 ステップを次の Effect に接ぐ。Catch は Sequence の短絡境界:
    # 成功時は素通りし、直前が Err のときだけ (かつ catches? が真のとき) 回復させる。
    # 非 Catch は Err なら短絡 (prev を前送り)、Ok なら実行する。
    def compile_step(step, prev)
      return compile_catch(step, prev) if step.is_a?(Catch)
      return Darkcore.pure(prev) if prev.is_a?(Err)

      compile(step).call(prev.focus)
    end

    def compile_catch(step, prev)
      return Darkcore.pure(prev) unless prev.is_a?(Err) && step.catches?(prev)

      Darkcore.pure(recover(step.handler, prev))
    end

    # berylx ノードと初期 focus から darkcore Effect 木を組み立てる。
    # 実行はしない (handler を渡すまで作用は起きない)。
    def build(node, focus)
      compile(node).call(Result.coerce_focus(focus))
    end

    # workflow 本体 (Effect 木) を darkcore トランポリンで走らせる。
    # handlers を差し替えるだけで圏 (real / dry_run / audit ...) を選ぶ。
    # 戻り値は berylx の結果封筒 Berylx::Ok(lay) / Berylx::Err(partial_lay, error)。
    def run(node, focus, handlers: real_handlers)
      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end

    # 実実行の handler マップ: Task の block を実際に呼び、合成子ノードは
    # それぞれ副木として実行しつつ berylx 圏の algebra で結果封筒を合成する。
    # Task#call / 各合成子の call と同一のセマンティクスになるよう写している。
    #
    # 合成子 handler は自分自身 (handlers) を副木実行に渡すため、木は
    # 同じ圏 (real) のまま再帰する。dry-run 側も同じ再帰構造を持つので、
    # aspect (real / dry) は handler マップの差し替えだけで切り替わる。
    def real_handlers
      {
        TASK => ->(payload) { real_task(payload) },
        PARALLEL => ->(payload) { real_parallel(payload) },
        BRANCH => ->(payload) { real_branch(payload) },
        RESCUE => ->(payload) { real_rescue(payload) }
      }
    end

    def real_task(payload)
      task, focus = payload
      task.call(focus)
    end

    def real_parallel(payload)
      run_parallel(payload[0], payload[1], real_handlers)
    end

    def real_branch(payload)
      run_branch(payload[0], payload[1], real_handlers)
    end

    def real_rescue(payload)
      run_rescue(payload[0], payload[1], real_handlers)
    end

    # ----------------------------------------------------------------
    # 副木実行ヘルパ — berylx ノードを与えられた handler マップで走らせ、
    # berylx 結果封筒 (Ok/Err) を得る。合成子 handler が枝の実行に使う。
    # ----------------------------------------------------------------
    def run_subtree(node, focus, handlers)
      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end
  end
end

# 合成子 (parallel / branch / rescue) の real interpreter は別ファイルで
# EffectTree を再オープンして足す。core (compile / build / run / handler マップ)
# と、各合成子の berylx 圏 algebra (短絡・merge・回復) を語りの上でも分離する。
require_relative 'effect_tree/combinators'

# dry-run interpreter (aspect) も別ファイルで EffectTree を再オープンして足す。
# real interpreter と dry interpreter を語り (ファイル) の上でも分離し、
# aspect が handler マップ差し替えだけで載ることを構造で示す。
require_relative 'effect_tree/dry_run'
