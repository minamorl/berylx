# frozen_string_literal: true

# berylx orchestration benchmark — native bridge / pure Ruby fold / 生 proc 床。
#
#   ruby bench/bench.rb            # native bridge (コンパイル済みなら) + pure Ruby
#   BERYLX_NATIVE=0 ruby bench.rb  # gate を殺して pure Ruby のみ
#
# pure Rust の床 (同型 3 実装: naive Freer O(n^2) / O(n) Freer / 直接 walker) は
#   cd bench/rust_baseline && cargo build --release && ./target/release/berylx_rust_baseline
#
# 数字の読み方 (正直さのために):
#   - identity タスクは「オーケストレーション費そのもの」を測る顕微鏡。
#   - counter タスクは Focus 更新 1 回を含む現実寄りの下限。実務の task body は
#     さらに重いので、body が支配する workflow では native の利得は薄まる (Amdahl)。
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
sibling = File.expand_path('../../darkcore-ruby/lib', __dir__)
$LOAD_PATH.unshift sibling if File.directory?(sibling)
require 'berylx'

def chain(size, kind)
  tasks = (1..size).map do |i|
    case kind
    when :identity then Berylx::Task[:"t#{i}"] { |l| l }
    when :counter  then Berylx::Task[:"t#{i}"] { |l| l[:count].update { _1 + 1 } }
    end
  end
  tasks.reduce(:>>)
end

def measure(iters, &block)
  yield # warmup
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iters.times(&block)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) / iters
end

def row(label, size, iters, &block)
  dt = measure(iters, &block)
  puts format('%<label>-34s n=%<size>-6d %<us>12.1f us %<ns>10.1f ns/step',
              label: label, size: size, us: dt * 1e6, ns: dt * 1e9 / size)
end

native = Berylx::EffectTree::Native.enabled?
puts "berylx #{Berylx::VERSION}  ruby #{RUBY_VERSION}  native_bridge=#{native}"
puts

pure = Berylx::EffectTree.real_handlers.dup # gate を外して純 Ruby fold を強制

[200, 1000, 3000].each do |n|
  wf = chain(n, :identity)
  focus = Berylx::Focus[{ count: 0 }]
  iters = n >= 3000 ? 20 : 50
  row('identity  effect_tree (default)', n, iters) { Berylx::EffectTree.run(wf, focus) }
  row('identity  effect_tree (pure)', n, iters) { Berylx::EffectTree.run(wf, focus, handlers: pure) }
  puts
end

wf = chain(1000, :counter)
focus = Berylx::Focus[{ count: 0 }]
raise 'bad counter result' unless Berylx::EffectTree.run(wf, focus).focus.to_h[:count] == 1000

row('counter   effect_tree (default)', 1000, 30) { Berylx::EffectTree.run(wf, focus) }
row('counter   effect_tree (pure)', 1000, 30) { Berylx::EffectTree.run(wf, focus, handlers: pure) }
puts

blocks = (1..1000).map { ->(h) { h } }
row('identity  raw proc loop (床)', 1000, 200) do
  acc = { count: 0 }
  blocks.each { |b| acc = b.call(acc) }
  acc
end
