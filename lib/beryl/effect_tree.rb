# frozen_string_literal: true

require 'darkcore'

module Beryl
  # ==================================================================
  # Beryl::EffectTree — beryl workflow を darkcore の単一 Effect 型
  # (Freer monad, tagged effect の木) へ載せ替える adapter。
  #
  # 第一段: Sequence(>>) の写像のみ。parallel(&) / branch / rescue は
  # spec-system で free/quarantine 保留のため触らない。
  #
  # 掟 (spec-system pins) との対応:
  #   - substrate.effect_tree      : workflow を darkcore Effect 木へ写す。
  #   - substrate.task_as_effect   : Task を tagged effect ノード
  #       Effect(:beryl_task, [task, focus], k) として表す。
  #   - substrate.no_opaque_thunk  : payload は検査可能なデータ (Task+Focus)。
  #       Task の block は handler が呼ぶまで実行しない。
  #   - substrate.aspect_via_handler: retry/dry_run/audit は workflow 本体
  #       (compile 結果の Effect 木) を書き換えず handler マップ差し替えで後付け。
  #   - result.envelope            : 成功 Beryl::Ok(lay) / 失敗 Beryl::Err(partial_lay, error)。
  #   - result.sequence_short_circuit: 最初の Err で短絡 (darkcore bind の上に載せる)。
  #   - namespace.separate         : darkcore の bind は必ず bind と呼ぶ。
  #       beryl の >> は beryl の合成子として残す (ここでは演算子を作らない)。
  #
  # darkcore 側の掟: bind は構造の接ぎ木のみ (演算ゼロ)。圏の algebra が
  # 現れるのは handler と on_return だけ。ここでの短絡判定 (Err かどうか) は
  # beryl の Result 圏の algebra なので、darkcore の bind に埋めず、beryl 側の
  # 継続 (bind に渡す関数) の中で行う。
  # ==================================================================
  module EffectTree
    # Task を darkcore Effect 木にディスパッチするためのタグ。
    TASK = :beryl_task

    # dry_run の戻り値: 最終結果 (実行しないので常に Ok) と、列挙された計画。
    DryRun = Data.define(:result, :steps)

    module_function

    # ----------------------------------------------------------------
    # compile — beryl ノードを「Focus を受け取り darkcore Effect を返す」
    # Kleisli 矢に落とす。第一段では Task と Sequence のみ対応する。
    # ----------------------------------------------------------------
    def compile(node)
      case node
      when Sequence
        arrows = node.steps.map { |step| compile(step) }
        lambda do |focus|
          arrows.reduce(Darkcore.pure(Result.ok(focus))) do |effect, arrow|
            # darkcore の bind は構造の接ぎ木。短絡 (Err) 判定はこの継続内 =
            # beryl 圏の algebra site で行う (darkcore bind には埋めない)。
            effect.bind do |prev|
              prev.is_a?(Err) ? Darkcore.pure(prev) : arrow.call(prev.focus)
            end
          end
        end
      when Task
        # Task を不透明サンクにせず tagged effect ノードとして表す。
        # payload = [task, focus] は検査可能なデータ (task.name も読める)。
        ->(focus) { Darkcore.op(TASK, [node, focus]) }
      else
        raise ArgumentError,
              "EffectTree (stage 1) supports Task / Sequence only, got #{node.class}"
      end
    end

    # beryl ノードと初期 focus から darkcore Effect 木を組み立てる。
    # 実行はしない (handler を渡すまで作用は起きない)。
    def build(node, focus)
      compile(node).call(Result.coerce_focus(focus))
    end

    # workflow 本体 (Effect 木) を darkcore トランポリンで走らせる。
    # handlers を差し替えるだけで圏 (real / dry_run / audit ...) を選ぶ。
    # 戻り値は beryl の結果封筒 Beryl::Ok(lay) / Beryl::Err(partial_lay, error)。
    def run(node, focus, handlers: real_handlers)
      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end

    # 実実行の handler マップ: Task の block を実際に呼ぶ。
    # Task#call が Ok/Err への正規化・失敗コンテキスト付与・例外捕捉まで担うので、
    # legacy 実行 (Sequence#call → step.call) と同一のセマンティクスになる。
    def real_handlers
      {
        TASK => lambda do |payload|
          task, focus = payload
          task.call(focus)
        end
      }
    end

    # dry-run: workflow 本体を書き換えず handler 差し替えだけで、Task を
    # 実行せずに計画 (Task 名の列) を列挙する。常に Ok(focus) を返すため
    # 短絡せず全ステップを辿る。
    def dry_run(node, focus)
      steps = []
      handlers = {
        TASK => lambda do |payload|
          task, foc = payload
          steps << task.name
          Result.ok(foc) # Task の block は呼ばない (副作用ゼロ)。
        end
      }
      DryRun.new(run(node, focus, handlers: handlers), steps)
    end
  end
end
