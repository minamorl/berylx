// berylx_rust_baseline — berylx と同型のワークフロー実行を pure Rust (std のみ)
// で 3 通りに実装し、「言語の寄与」と「アルゴリズムの寄与」を分離して測る。
//
//   1. freer_left  : darkcore と同じ Freer monad を左結合 bind で積む
//                    (= berylx 旧実装の写し。継続を毎回再ラップして O(n^2))
//   2. freer_right : 同じ Freer monad を右結合で接ぐ (= berylx 現実装の写し。O(n))
//   3. walker      : effect ノードを作らず直接ステップ列を歩く
//                    (= C bridge の写し。ネイティブ実行の床)
//
// タスク本体は identity / counter の 2 種。状態は i64 (Rust に最も有利な条件)。
// これは「berylx が Rust に勝つ」ためのハンデ戦ではなく、逆に Rust へ全面的に
// 有利な土俵での正直な床の測定である。

use std::time::Instant;

type Env = i64;

enum Effect {
    Pure(Env),
    Op {
        payload: Env,
        k: Box<dyn FnOnce(Env) -> Effect>,
    },
}

fn op(payload: Env) -> Effect {
    Effect::Op {
        payload,
        k: Box::new(Effect::Pure),
    }
}

fn bind(e: Effect, f: Box<dyn FnOnce(Env) -> Effect>) -> Effect {
    match e {
        Effect::Pure(x) => f(x),
        Effect::Op { payload, k } => Effect::Op {
            payload,
            k: Box::new(move |x| bind(k(x), f)),
        },
    }
}

fn fold(mut cur: Effect, handler: impl Fn(Env) -> Env) -> Env {
    loop {
        match cur {
            Effect::Pure(x) => return x,
            Effect::Op { payload, k } => cur = k(handler(payload)),
        }
    }
}

// 1. 左結合 (darkcore + berylx 旧 compile_sequence の写し): O(n^2)
fn run_freer_left(n: usize, inc: Env) -> Env {
    let mut e = Effect::Pure(0);
    for _ in 0..n {
        e = bind(e, Box::new(op));
    }
    fold(e, |x| x + inc)
}

// 2. 右結合 (berylx 現 compile_sequence の写し): O(n)
fn run_freer_right(n: usize, inc: Env) -> Env {
    fn chain(i: usize, n: usize, x: Env) -> Effect {
        if i >= n {
            return Effect::Pure(x);
        }
        bind(op(x), Box::new(move |y| chain(i + 1, n, y)))
    }
    fold(chain(0, n, 0), |x| x + inc)
}

// 3. 直接 walker (C bridge の写し): effect ノードを作らない床
fn run_walker(tasks: &[Box<dyn Fn(Env) -> Result<Env, ()>>]) -> Result<Env, ()> {
    let mut acc: Env = 0;
    for t in tasks {
        acc = t(acc)?;
    }
    Ok(acc)
}

fn bench<F: FnMut() -> Env>(label: &str, n: usize, iters: u32, mut f: F) {
    f(); // warmup
    let t0 = Instant::now();
    let mut sink = 0;
    for _ in 0..iters {
        sink ^= f();
    }
    let dt = t0.elapsed().as_secs_f64() / iters as f64;
    println!(
        "{:<28} n={:<6} {:>12.3} us  {:>8.1} ns/step   (sink={})",
        label,
        n,
        dt * 1e6,
        dt * 1e9 / n as f64,
        sink
    );
}

fn main() {
    for &n in &[1000usize, 3000, 10000] {
        let iters: u32 = if n >= 10000 { 50 } else { 200 };
        bench("freer_left  (naive O(n^2))", n, if n > 3000 { 5 } else { iters }, || {
            run_freer_left(n, 1)
        });
        bench("freer_right (O(n) queue)", n, iters, || run_freer_right(n, 1));
        let tasks: Vec<Box<dyn Fn(Env) -> Result<Env, ()>>> =
            (0..n).map(|_| Box::new(|x: Env| Ok(x + 1)) as _).collect();
        bench("walker      (direct)", n, iters, || {
            run_walker(&tasks).unwrap_or(-1)
        });
        println!();
    }
}
