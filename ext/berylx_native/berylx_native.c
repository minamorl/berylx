/*
 * berylx_native — EffectTree の real 圏専用 native interpreter (C bridge)。
 *
 * 役割は「構造のディスパッチ」だけ:
 *   - Sequence: ステップ列の反復・Err 短絡の前送り・Catch 境界の走査
 *   - Branch:   arm の述語評価と本体の選択
 *   - Rescue:   body 実行と回復への委譲
 *   - Task:     Task#call への委譲 (封筒正規化・例外捕捉は Ruby 側の正本)
 *   - Parallel: Ruby 側 shim (Native.run_parallel) へ委譲 (Thread 意味論を保持)
 *
 * berylx 圏の algebra (封筒の合成・回復・merge) は一切ここに実装しない。
 * EffectTree.recover / parallel_* / Task#call という既存の Ruby 実装を
 * そのまま呼ぶことで、意味の単一正本を保つ (native_equivalence_test が
 * pure Ruby fold との構造同一性を全合成子で検証する)。
 *
 * handler マップを差し替えた圏 (dry_run / audit / retry ...) はこの橋を
 * 通らず、従来どおり pure Ruby の Darkcore.fold で走る (aspect_via_handler)。
 */

#include <ruby.h>

static VALUE c_task, c_sequence, c_parallel, c_branch, c_rescue, c_catch;
static VALUE c_ok, c_err, m_result, m_effect_tree, m_native;
static ID id_call, id_focus, id_steps, id_catches_p, id_handler, id_arms,
    id_predicate, id_body, id_else_branch, id_block, id_new, id_recover,
    id_run_parallel, id_err_ctor;
static VALUE sym_no_branch_matched;
static int refs_ready = 0;

/*
 * Berylx の定数群は berylx.rb のロード後に初めて解決できるので、
 * 最初の実行時に一度だけ引いて static に固定する。固定した VALUE は
 * GC ルートとして登録する (定数からも到達可能だが、belt & braces)。
 */
static void
ensure_refs(void)
{
    VALUE m_berylx;

    if (refs_ready) return;

    m_berylx      = rb_const_get(rb_cObject, rb_intern("Berylx"));
    c_task        = rb_const_get(m_berylx, rb_intern("Task"));
    c_sequence    = rb_const_get(m_berylx, rb_intern("Sequence"));
    c_parallel    = rb_const_get(m_berylx, rb_intern("Parallel"));
    c_branch      = rb_const_get(m_berylx, rb_intern("Branch"));
    c_rescue      = rb_const_get(m_berylx, rb_intern("Rescue"));
    c_catch       = rb_const_get(m_berylx, rb_intern("Catch"));
    c_ok          = rb_const_get(m_berylx, rb_intern("Ok"));
    c_err         = rb_const_get(m_berylx, rb_intern("Err"));
    m_result      = rb_const_get(m_berylx, rb_intern("Result"));
    m_effect_tree = rb_const_get(m_berylx, rb_intern("EffectTree"));
    m_native      = rb_const_get(m_effect_tree, rb_intern("Native"));

    rb_gc_register_address(&c_task);
    rb_gc_register_address(&c_sequence);
    rb_gc_register_address(&c_parallel);
    rb_gc_register_address(&c_branch);
    rb_gc_register_address(&c_rescue);
    rb_gc_register_address(&c_catch);
    rb_gc_register_address(&c_ok);
    rb_gc_register_address(&c_err);
    rb_gc_register_address(&m_result);
    rb_gc_register_address(&m_effect_tree);
    rb_gc_register_address(&m_native);

    refs_ready = 1;
}

static VALUE run_node_c(VALUE node, VALUE focus);

static int
is_err(VALUE v)
{
    return RTEST(rb_obj_is_kind_of(v, c_err));
}

static VALUE
ok_of(VALUE focus)
{
    return rb_funcall(c_ok, id_new, 1, focus);
}

/*
 * Sequence — compile_sequence / compile_step / compile_catch と同一の
 * 観測挙動を、Effect ノードを作らず反復で辿る:
 *   - Catch: 直前が Err かつ catches? のときだけ EffectTree.recover へ。
 *            それ以外は素通り (Ok は触らない)。
 *   - Err:   非 Catch ステップを実行せず前送り (短絡)。
 *   - Ok:    次のステップへ focus を渡して実行。
 */
static VALUE
run_sequence(VALUE node, VALUE focus)
{
    VALUE steps = rb_funcall(node, id_steps, 0);
    long len = RARRAY_LEN(steps);
    VALUE prev = ok_of(focus);
    long i;

    for (i = 0; i < len; i++) {
        VALUE step = rb_ary_entry(steps, i);

        if (RTEST(rb_obj_is_kind_of(step, c_catch))) {
            if (is_err(prev) && RTEST(rb_funcall(step, id_catches_p, 1, prev))) {
                VALUE handler = rb_funcall(step, id_handler, 0);
                prev = rb_funcall(m_effect_tree, id_recover, 2, handler, prev);
            }
            continue;
        }
        if (is_err(prev)) continue;

        prev = run_node_c(step, rb_funcall(prev, id_focus, 0));
    }
    return prev;
}

/*
 * Branch — run_branch / branch_matches? と同一: else arm は述語を呼ばず
 * 常に match、それ以外は predicate.block.call(focus) の真偽で選ぶ。
 * どの arm も match しなければ Result.err(focus, :no_branch_matched)。
 */
static VALUE
run_branch(VALUE node, VALUE focus)
{
    VALUE arms = rb_funcall(node, id_arms, 0);
    long len = RARRAY_LEN(arms);
    long i;

    for (i = 0; i < len; i++) {
        VALUE arm = rb_ary_entry(arms, i);
        VALUE pred = rb_funcall(arm, id_predicate, 0);
        VALUE matched = rb_funcall(pred, id_else_branch, 0);

        if (!RTEST(matched)) {
            VALUE blk = rb_funcall(pred, id_block, 0);
            matched = rb_funcall(blk, id_call, 1, focus);
        }
        if (RTEST(matched)) {
            return run_node_c(rb_funcall(arm, id_body, 0), focus);
        }
    }
    return rb_funcall(m_result, id_err_ctor, 2, focus, sym_no_branch_matched);
}

/*
 * Rescue — run_rescue と同一: body が Ok ならそのまま、そうでなければ
 * EffectTree.recover (RescueBlock / task handler の algebra) へ委譲。
 */
static VALUE
run_rescue(VALUE node, VALUE focus)
{
    VALUE result = run_node_c(rb_funcall(node, id_body, 0), focus);

    if (RTEST(rb_obj_is_kind_of(result, c_ok))) return result;

    return rb_funcall(m_effect_tree, id_recover, 2,
                      rb_funcall(node, id_handler, 0), result);
}

/*
 * dispatcher — EffectTree.compile の case 節と同じ順・同じ対応:
 *   Sequence / Task / Parallel / Branch / Rescue / Catch。
 * Task は Task#call (coerce + normalize + 文脈付与 + 例外捕捉) へ、
 * Parallel は Ruby shim (Thread 意味論 + 失敗合成/merge の正本) へ委譲。
 * 未知ノードは compile と同文の ArgumentError。
 */
static VALUE
run_node_c(VALUE node, VALUE focus)
{
    if (RTEST(rb_obj_is_kind_of(node, c_sequence))) return run_sequence(node, focus);
    if (RTEST(rb_obj_is_kind_of(node, c_task)))     return rb_funcall(node, id_call, 1, focus);
    if (RTEST(rb_obj_is_kind_of(node, c_parallel))) return rb_funcall(m_native, id_run_parallel, 2, node, focus);
    if (RTEST(rb_obj_is_kind_of(node, c_branch)))   return run_branch(node, focus);
    if (RTEST(rb_obj_is_kind_of(node, c_rescue)))   return run_rescue(node, focus);
    if (RTEST(rb_obj_is_kind_of(node, c_catch)))    return ok_of(focus);

    rb_raise(rb_eArgError,
             "EffectTree supports Task / Sequence / Parallel / Branch / Rescue / Catch, got %"PRIsVALUE,
             rb_obj_class(node));
}

static VALUE
native_run_node(VALUE self, VALUE node, VALUE focus)
{
    (void)self;
    ensure_refs();
    return run_node_c(node, focus);
}

void
Init_berylx_native(void)
{
    VALUE m_berylx = rb_define_module("Berylx");
    VALUE m_et = rb_define_module_under(m_berylx, "EffectTree");
    VALUE m_nat = rb_define_module_under(m_et, "Native");

    id_call         = rb_intern("call");
    id_focus        = rb_intern("focus");
    id_steps        = rb_intern("steps");
    id_catches_p    = rb_intern("catches?");
    id_handler      = rb_intern("handler");
    id_arms         = rb_intern("arms");
    id_predicate    = rb_intern("predicate");
    id_body         = rb_intern("body");
    id_else_branch  = rb_intern("else_branch");
    id_block        = rb_intern("block");
    id_new          = rb_intern("new");
    id_recover      = rb_intern("recover");
    id_run_parallel = rb_intern("run_parallel");
    id_err_ctor     = rb_intern("err");

    sym_no_branch_matched = ID2SYM(rb_intern("no_branch_matched"));

    rb_define_singleton_method(m_nat, "run_node", native_run_node, 2);
}
