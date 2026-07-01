# Composing workflows

Beryl workflows are named Ruby values that compose into sequences, branches, parallel groups, and
recovery scopes.

## Tasks and sequencing

A task is a named transition from `Lay` to `Result[Lay]`:

```ruby
validate = Beryl::Task[:validate] do |lay|
  lay[:account_id].present? ? lay : lay.reject(:missing_account)
end

load_account = Beryl::Task[:load_account] do |lay|
  lay[:account].set(Account.find(lay[:account_id].get))
end

workflow = validate >> load_account
```

`>>` is short-circuiting. An `Ok` passes its lay to the next task; an `Err` skips ordinary steps
until a matching recovery boundary is reached or the workflow returns.

Run a complete workflow from a committing root:

```ruby
result = root | workflow
```

Or evaluate it from a standalone lay:

```ruby
result = workflow.call(Beryl::Lay[account_id: 42])
```

## Branching

Use `When` and `Else` for predicate-based choice:

```ruby
paid = Beryl::Task[:paid] { |lay| lay[:status].set(:paid) }
trial = Beryl::Task[:trial] { |lay| lay[:status].set(:trial) }

branch =
  (Beryl::When[:paid] { |lay| lay[:plan].get == :paid } >> paid) |
  (Beryl::Else >> trial)

result = branch.call(Beryl::Lay[plan: :paid])
result.focus[:status].get
# => :paid
```

Branch `Else` is a predicate fallback. It is not an error handler; use `Catch` or `rescue_with` for
failures.

## Parallel workflows

`&` starts sibling branches from the same input snapshot. A reducer combines their returned lays:

```ruby
left = Beryl::Task[:left] do |lay|
  lay[:left].set(lay[:base].get + 1)
end

right = Beryl::Task[:right] do |lay|
  lay[:right].set(lay[:base].get + 2)
end

workflow = (left & right).reduce(Beryl::Merge.deep)
result = workflow.call(Beryl::Lay[base: 10])

result.focus.to_h
# => { base: 10, left: 11, right: 12 }
```

Parallel branches never mutate a shared lay. Choose the merge policy explicitly:

| Reducer                   | Behavior                                                                     |
| ------------------------- | ---------------------------------------------------------------------------- |
| `Beryl::Merge.keep_left`  | Keep the accumulated left focus                                              |
| `Beryl::Merge.keep_right` | Keep the right branch focus                                                  |
| `Beryl::Merge.deep`       | Deep-merge hashes; the right value wins scalar conflicts                     |
| `Beryl::Merge.strict`     | Merge independent changes and return `:merge_conflict` for conflicting paths |

```ruby
left = Beryl::Task[:left] { |lay| lay[:status].set(:paid) }
right = Beryl::Task[:right] { |lay| lay[:status].set(:trial) }

result = (left & right)
  .reduce(Beryl::Merge.strict)
  .call(Beryl::Lay[status: nil])

result.code
# => :merge_conflict
```

Parallel failure information is available through `result.parallel_errors`. See
[Errors and recovery](error-handling.md).

## Named workflows and graphs

Wrap a composition in `Workflow` when the whole procedure deserves a name:

```ruby
workflow = Beryl::Workflow[:checkout] do
  validate >> (reserve_inventory & authorize_payment).reduce(Beryl::Merge.strict) >> confirm
end
```

Named tasks survive compilation:

```ruby
graph = workflow.compile

graph.nodes
# => named workflow nodes

graph.to_dot
# => digraph "checkout" {
#      "validate#0";
#      "split#1";
#      "join#2";
#      "split#1" -> "reserve_inventory#3";
#      "reserve_inventory#3" -> "join#2";
#      "split#1" -> "authorize_payment#4";
#      "authorize_payment#4" -> "join#2";
#      "confirm#5";
#      "validate#0" -> "split#1";
#      "join#2" -> "confirm#5";
#    }
```

Consecutive steps chain with edges, a parallel group fans out through a synthetic `split`/`join`
pair, and branch arms carry the predicate name (or `else`) as an edge label. Node ids are
index-suffixed so repeated task names stay distinct.

This makes the executable workflow shape available for documentation, visualization, and
instrumentation without a second declarative DSL.

## Recovery is composition

`Catch` can sit inline in a sequence, while `rescue_with` wraps an explicit subgraph:

```ruby
inline = charge >> Beryl::Catch[:refund] { |error, lay| compensate(error, lay) } >> notify

scoped =
  (charge >> create_subscription)
    .rescue_with(:refund) { |error, lay| compensate(error, lay) } >>
  notify
```

Read [Errors and recovery](error-handling.md) for propagation, partial state, fatal errors, and
handler behavior.
