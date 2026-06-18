# beryl

A Ruby-native workflow gem for composing named tasks over focused state.

Beryl is not an IO/effect system and not a replacement for Rails. It is a small algebraic layer for
business workflows: tasks are values, workflows are values, state flows through a focus, and control
shapes such as sequence, parallel, branch, and rescue are explicit nodes instead of hidden service
object control flow.

## Install

```ruby
gem "beryl"
```

```sh
bundle install
```

## Core syntax

```ruby
require "beryl"

strip =
  Beryl::Task[:strip] do |root|
    root[:name].update(&:strip)
  end

greet =
  Beryl::Task[:greet] do |root|
    root[:greeting].set("hello #{root[:name].get}")
  end

workflow =
  Beryl::Workflow[:hello] do
    strip >> greet
  end

result = workflow.call(Beryl::Focus[name: "  mina  "])
# => Beryl::Ok(focus)

result.focus.to_h
# => { name: "mina", greeting: "hello mina" }
```

The public surface is intentionally small:

- `Task[:name] { |root| ... }`
- `Workflow[:name] { ... }`
- `a >> b` for sequential execution
- `a & b` for parallel execution
- `(When[:case] { ... } >> task) | (Else >> fallback)` for branch / else
- `flow.rescue_with(handler_task)` or `flow.rescue_with(:name) { |error, root| ... }`
- `Focus[...]` as the built-in focused state object
- `Ok(focus)` / `Err(focus, code, message, cause)` as explicit results

No `Effect`, no `reads`, no `writes`, no `requires`, no `returns`, no `Task / lens` outer syntax.
Task bodies receive a focus and use it inside the block.

## Rails example: subscription workflow

Beryl works best as a replacement for large Rails service objects that hide orchestration inside one
`call` method. Rails remains Rails: ActiveRecord, ActionMailer, ActiveJob, Stripe clients,
repository objects, transactions, and authorization all stay ordinary Ruby.

```ruby
# app/workflows/subscribe_user.rb
require "beryl"

load_user =
  Beryl::Task[:load_user] do |root|
    root[:user].set(User.find(root[:input][:user_id].get))
  end

load_plan =
  Beryl::Task[:load_plan] do |root|
    root[:plan].set(Plan.find(root[:input][:plan_id].get))
  end

create_stripe_customer =
  Beryl::Task[:create_stripe_customer] do |root|
    user = root[:user].get
    customer = Stripe::Customer.create(email: user.email)

    root[:stripe_customer_id].set(customer.id)
  end

charge_first_payment =
  Beryl::Task[:charge_first_payment] do |root|
    plan = root[:plan].get

    payment = Stripe::PaymentIntent.create(
      customer: root[:stripe_customer_id].get,
      amount: plan.price_cents,
      currency: "jpy",
      payment_method: root[:input][:payment_token].get,
      confirm: true
    )

    root[:stripe_payment_intent_id].set(payment.id)
  end

create_subscription =
  Beryl::Task[:create_subscription] do |root|
    subscription = Subscription.create!(
      user: root[:user].get,
      plan: root[:plan].get,
      stripe_customer_id: root[:stripe_customer_id].get,
      stripe_payment_intent_id: root[:stripe_payment_intent_id].get,
      status: "active"
    )

    root[:subscription].set(subscription)
  end

send_started_mail =
  Beryl::Task[:send_started_mail] do |root|
    UserMailer.subscription_started(root[:user].get, root[:subscription].get).deliver_later
    root
  end

write_audit_log =
  Beryl::Task[:write_audit_log] do |root|
    AuditLog.create!(
      actor: root[:user].get,
      action: "subscription.started",
      record: root[:subscription].get
    )

    root
  end

refund_payment =
  Beryl::Task[:refund_payment] do |root|
    Stripe::Refund.create(payment_intent: root[:stripe_payment_intent_id].get)
    root[:refunded].set(true)
  end

subscribe_user =
  Beryl::Workflow[:subscribe_user] do
    (load_user & load_plan).reduce(Beryl::Merge.deep) >>
      create_stripe_customer >>
      charge_first_payment >>
      create_subscription >>
      (send_started_mail & write_audit_log).reduce(Beryl::Merge.keep_left)
  end

safe_subscribe_user = subscribe_user.body.rescue_with(refund_payment)

root = Beryl::Focus[
  input: {
    user_id: params[:user_id],
    plan_id: params[:plan_id],
    payment_token: params[:payment_token]
  }
]

Beryl.run(safe_subscribe_user, root)
```

The comparable service object can look shorter, but the workflow shape is trapped inside one method.
With Beryl, the flow itself is inspectable and testable as a value.

```ruby
graph = subscribe_user.compile

graph.nodes
# => [:load_user, :load_plan, :create_stripe_customer, :charge_first_payment,
#     :create_subscription, :send_started_mail, :write_audit_log]

graph.parallel_nodes
# => [[:load_user, :load_plan], [:send_started_mail, :write_audit_log]]

graph.to_dot
# => renderable DOT graph
```

## Error rescue syntax

Use a task when compensation is also a named workflow node.

```ruby
charge = Beryl::Task[:charge] do |root|
  root[:payment].set(Stripe::PaymentIntent.create!(...))
end

create_subscription = Beryl::Task[:create_subscription] do |root|
  root[:subscription].set(Subscription.create!(...))
end

refund = Beryl::Task[:refund] do |root|
  Stripe::Refund.create(payment_intent: root[:payment].get.id)
  root[:refunded].set(true)
end

flow = (charge >> create_subscription).rescue_with(refund)
```

Use a block when the rescue is local and small.

```ruby
flow =
  (charge >> create_subscription).rescue_with(:mark_failed) do |error, root|
    root[:failure].set(error.message)
  end
```

A task exception becomes `Err(partial_focus, code, message, cause)`. Rescue receives the partial
focus, so compensation can still see state produced before the failure.

## Parallel execution syntax

`&` means promise-like horizontal execution. Each branch receives the same input snapshot. The
parent combines successful branch focuses with an explicit reducer.

```ruby
load_user = Beryl::Task[:load_user] { |root| root[:user].set(User.find(root[:user_id].get)) }
load_plan = Beryl::Task[:load_plan] { |root| root[:plan].set(Plan.find(root[:plan_id].get)) }

hydrate = (load_user & load_plan).reduce(Beryl::Merge.deep)
```

Parallel branches do not share a mutable focus. They run independently and return their own focuses.
If any branch returns `Err`, the parallel node returns that error. If all branches return `Ok`, the
reducer combines them.

Built-in reducers:

```ruby
Beryl::Merge.deep       # deep merge focus hashes
Beryl::Merge.keep_left  # keep accumulated parent focus
Beryl::Merge.keep_right # keep the latest branch focus
```

## Branch and else syntax

Use `When >> task` arms joined by `|`. Use `Else` as the final fallback.

```ruby
paid_flow = Beryl::Task[:paid_flow] { |root| root[:status].set(:paid) }
trial_flow = Beryl::Task[:trial_flow] { |root| root[:status].set(:trial) }

choose_plan =
  (Beryl::When[:paid] { |root| root[:plan].get == :paid } >> paid_flow) |
  (Beryl::Else >> trial_flow)
```

Inside a workflow:

```ruby
signup =
  Beryl::Workflow[:signup] do
    load_account >>
      (
        (Beryl::When[:paid] { |root| root[:account].get.paid? } >> paid_flow) |
        (Beryl::Else >> trial_flow)
      ) >>
      write_audit_log
  end
```

Ruby operator precedence matters. Prefer parentheses around branch arms.

## TDD status

The current implementation was driven red-first from Minitest coverage for:

- task sequencing over focus
- promise-like parallel execution with explicit reducers
- branch / else syntax
- rescue with task compensation
- rescue with block handler
- graph compilation exposing nodes and parallel groups

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
gem build beryl.gemspec
npm install
npm run format:check
```

CI runs tests, RuboCop, gem build, and Prettier on GitHub Actions.
