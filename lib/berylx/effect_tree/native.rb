# frozen_string_literal: true

begin
  require 'berylx_native/berylx_native'
rescue LoadError
  # C 拡張が無い環境 (未コンパイル / 非対応プラットフォーム) では
  # 純 Ruby interpreter へ静かにフォールバックする。挙動は同一 (差分検証で保証)。
end

module Berylx
  module EffectTree
    # ==================================================================
    # Berylx::EffectTree::Native — real 圏専用 C interpreter への橋。
    #
    # 役割分担 (semantics は Ruby が単一正本):
    #   - C 側 (run_node) は「構造のディスパッチ」だけを持つ:
    #     Sequence の反復・短絡・Catch 境界の走査、Branch の arm 選択、
    #     Rescue の body 実行、Task ノードから Task#call への委譲。
    #   - berylx 圏の algebra (Task#call の封筒正規化・recover・
    #     parallel の失敗合成/merge) はすべて既存の Ruby 実装を呼ぶ。
    #     意味を二重実装しないので、native と pure Ruby は構造的に同じ
    #     結果封筒を返す (native_equivalence_test が全合成子で検証)。
    #
    # 掟 (spec-system pins) との整合:
    #   - substrate.effect_tree / task_as_effect: workflow の表現は従来どおり
    #     berylx ノード + darkcore Effect 木。native は real 圏の評価器を
    #     差し替えるだけで、第二の表現 (legacy 経路) を持ち込まない。
    #   - substrate.aspect_via_handler: handler マップを差し替えた圏
    #     (dry_run / audit / retry ...) は従来どおり pure Ruby の fold で走る。
    #     native が受けるのは既定 REAL_HANDLERS のままの real 圏だけ。
    # ==================================================================
    module Native
      class << self
        # C 拡張がロードできたか (run_node は C 側が生やす)。
        def available?
          respond_to?(:run_node)
        end

        # 実際に使うか。BERYLX_NATIVE=0 で強制的に純 Ruby へ落とせる。
        def enabled?
          available? && ENV.fetch('BERYLX_NATIVE', '1') != '0'
        end

        # EffectTree.run の real 圏ゲートから入る唯一の入口。
        # build と同じく入口で一度だけ Focus へ coerce する (内側では
        # pure Ruby 経路と同様、値をそのまま流す)。
        def run_entry(node, focus)
          run_node(node, Result.coerce_focus(focus))
        end

        # Parallel は Ruby の Thread 意味論 (枝ごとの Thread.new) を保つため
        # ここで枝を張り、枝の副木だけを C interpreter で走らせる。
        # 失敗合成 / merge の algebra は EffectTree の同じ関数を使う (単一正本)。
        def run_parallel(node, focus)
          threads = node.branches.map { |branch| Thread.new { run_node(branch, focus) } }
          results = threads.map(&:value)
          failures = results.grep(Err)
          return EffectTree.parallel_handle_failures(node, focus, failures) unless failures.empty?

          merged = EffectTree.parallel_merge(node, focus, results)
          merged.is_a?(Err) ? merged : Result.ok(merged)
        end
      end
    end
  end
end
