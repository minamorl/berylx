# beryl

A Ruby-native workflow gem for composing business tasks over one Root entity through Lay
observations.

Beryl is not Rails, not an effect system, and not a service-object generator. The shape is:

1. create one `Root` at the application boundary
2. observe and update it through `Lay` inside named tasks
3. compose tasks with sequence / parallel / branch / rescue operators
4. let successful task results commit back into the same `Root`
5. keep failures as `Err(partial_lay, error)` until you explicitly `unwrap`

## Install

```ruby
gem "beryl"
```

```sh
bundle install
```

## The API you should start with

```ruby
require "beryl"

root = Beryl.root(name: "  mina  ")

strip_name =
  Beryl.task :strip_name do |lay|
    lay[:name].update(&:strip)
  end

greet =
  Beryl.task :greet do |lay|
    name = lay[:name].get
    lay[:greeting].set("hello #{name}")
  end

result = root | strip_name | greet

case result
in Beryl::Ok(lay)
  puts lay[:greeting].get
in Beryl::Err(_lay, error)
  warn error.message
end

puts root.state
# {:name=>"mina", :greeting=>"hello mina"}
```

The public surface is intentionally small:

- `Beryl.root(...)` creates the boundary entity
- `Beryl.task(:name) { |lay| ... }` defines a named task
- `root | task` runs the task and commits the resulting Lay back into the same Root
- `a >> b` composes tasks sequentially
- `a & b` runs sibling tasks from the same snapshot and merges their results with `.reduce(...)`
- `flow.rescue_with(handler)` runs compensation against the partial Lay after failure
- `lay.reject(:code, "message")` returns a domain failure without raising
- `result.unwrap` projects Beryl failure back to ordinary Ruby exception space

No `reads`, no `writes`, no `requires`, no `returns`, no `Task / lens` outer syntax, no `commit:`
argument in app code. The Root is the thing. Lay is how a task sees it.

## Root / Lay / State

`Root` is the durable boundary object. `Lay` is the focused state view passed into task bodies.
`State` is the lower-level lifted execution space. Most application code should start from
`Beryl.root`.

```ruby
root = Beryl.root(
  request: { id: "req_01" },
  checkout: { user_id: 1 }
)

root.to_lay
root.to_state
root.state
```

Running a task from Root commits the task result back into the same Root.

```ruby
set_plan =
  Beryl.task :set_plan do |lay|
    lay[:checkout][:plan_id].set(3)
  end

root | set_plan

root.state
# {:request=>{:id=>"req_01"}, :checkout=>{:user_id=>1, :plan_id=>3}}
```

External observations can be committed too.

```ruby
root.commit(checkout: { coupon: "WELCOME" })

root.state
# {:request=>{:id=>"req_01"}, :checkout=>{:user_id=>1, :plan_id=>3, :coupon=>"WELCOME"}}
```

You can observe commits without turning the workflow into callbacks.

```ruby
events = []
unsubscribe = root.subscribe { |event| events << event }

root.commit(checkout: { source: "landing_page" })
unsubscribe.call

puts events
# [{:type=>:snapshot, :value=>...}, {:type=>:commit, :value=>...}]
```

## Complete usage: tiny Hono-like checkout app

This is a complete application-style example. It is deliberately not Rails. The route is thin,
dependencies are plain Ruby objects, and Beryl owns only the business flow shape.

```ruby
# app.rb
# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "roda"
require "beryl"

class MemoryStore
  attr_reader :users, :plans, :subscriptions, :audit_logs, :failures

  def initialize
    @users = {
      1 => { id: 1, email: "mina@example.com", name: "Mina" }
    }
    @plans = {
      10 => { id: 10, name: "Starter", price_cents: 1200, active: true },
      20 => { id: 20, name: "Pro", price_cents: 4800, active: true },
      30 => { id: 30, name: "Legacy", price_cents: 900, active: false }
    }
    @subscriptions = []
    @audit_logs = []
    @failures = []
  end

  def find_user(id)
    @users[id]
  end

  def find_active_plan(id)
    plan = @plans[id]
    return nil unless plan
    return nil unless plan.fetch(:active)

    plan
  end

  def active_subscription_for_user(user_id)
    @subscriptions.find do |subscription|
      subscription.fetch(:user_id) == user_id && subscription.fetch(:status) == "active"
    end
  end

  def create_subscription(user_id:, plan_id:, charge_id:)
    subscription = {
      id: @subscriptions.length + 1,
      user_id: user_id,
      plan_id: plan_id,
      charge_id: charge_id,
      status: "active",
      created_at: Time.now.iso8601
    }
    @subscriptions << subscription
    subscription
  end

  def write_audit_log(action:, user_id:, subject_id:, request_id:, payload:)
    audit_log = {
      id: @audit_logs.length + 1,
      action: action,
      user_id: user_id,
      subject_id: subject_id,
      request_id: request_id,
      payload: payload,
      created_at: Time.now.iso8601
    }
    @audit_logs << audit_log
    audit_log
  end

  def record_failure(user_id:, plan_id:, request_id:, code:, message:, payload:)
    failure = {
      id: @failures.length + 1,
      user_id: user_id,
      plan_id: plan_id,
      request_id: request_id,
      code: code,
      message: message,
      payload: payload,
      created_at: Time.now.iso8601
    }
    @failures << failure
    failure
  end
end

class Payments
  PaymentDeclined = Class.new(StandardError)

  def create_charge(user:, plan:, token:, idempotency_key:)
    raise PaymentDeclined, "card was declined" if token == "tok_declined"

    {
      id: "ch_#{SecureRandom.hex(8)}",
      idempotency_key: idempotency_key,
      user_id: user.fetch(:id),
      plan_id: plan.fetch(:id),
      amount: plan.fetch(:price_cents),
      token_last4: token[-4, 4],
      status: "succeeded",
      created_at: Time.now.iso8601
    }
  end

  def refund(charge_id:, reason:, idempotency_key:)
    {
      id: "rf_#{SecureRandom.hex(8)}",
      charge_id: charge_id,
      reason: reason,
      idempotency_key: idempotency_key,
      status: "refunded",
      created_at: Time.now.iso8601
    }
  end
end

class Mailer
  def deliver_subscription_started(email:, plan_name:, request_id:)
    {
      id: "mail_#{SecureRandom.hex(8)}",
      to: email,
      template: "subscription_started",
      plan_name: plan_name,
      request_id: request_id,
      queued: true
    }
  end
end

STORE = MemoryStore.new
PAYMENTS = Payments.new
MAILER = Mailer.new

module CheckoutWorkflow
  module_function

  def node
    safe_checkout
  end

  def call(root)
    root | node
  end

  def safe_checkout
    checkout.rescue_with(capture_exception) >>
      copy_failure_to_checkout >>
      refund_charge_if_needed >>
      record_failure >>
      return_failure
  end

  def checkout
    Beryl::Workflow[:checkout] do
      read_json_body >>
        normalize_input >>
        (load_user & load_plan).reduce(Beryl::Merge.deep) >>
        reject_duplicate_subscription >>
        create_charge >>
        create_subscription >>
        (deliver_receipt & write_success_audit_log).reduce(Beryl::Merge.deep)
    end
  end

  def read_json_body
    Beryl.task :read_json_body do |lay|
      request = lay[:http][:request].get
      body = request.body.read
      request.body.rewind if request.body.respond_to?(:rewind)

      return lay.reject(:empty_json_body, "request body is empty") if body.strip.empty?

      json = JSON.parse(body)
      return lay.reject(:invalid_json_body, "JSON body must be an object") unless json.is_a?(Hash)

      lay[:input].set(json)
    rescue JSON::ParserError => error
      lay.reject(:invalid_json_body, error.message, cause: error)
    end
  end

  def normalize_input
    Beryl.task :normalize_input do |lay|
      input = lay[:input].get
      user_id = Integer(input.fetch("user_id"))
      plan_id = Integer(input.fetch("plan_id"))
      payment_token = input.fetch("payment_token").to_s.strip

      return lay.reject(:invalid_payment_token, "payment_token is required") if payment_token.empty?

      lay = lay[:checkout][:user_id].set(user_id)
      lay = lay[:checkout][:plan_id].set(plan_id)
      lay[:checkout][:payment_token].set(payment_token)
    rescue KeyError, ArgumentError => error
      lay.reject(:bad_request, error.message, cause: error)
    end
  end

  def load_user
    Beryl.task :load_user do |lay|
      store = lay[:deps][:store].get
      user_id = lay[:checkout][:user_id].get
      user = store.find_user(user_id)

      return lay.reject(:user_not_found, "user #{user_id} not found") unless user

      lay[:checkout][:user].set(user)
    end
  end

  def load_plan
    Beryl.task :load_plan do |lay|
      store = lay[:deps][:store].get
      plan_id = lay[:checkout][:plan_id].get
      plan = store.find_active_plan(plan_id)

      return lay.reject(:plan_not_found, "active plan #{plan_id} not found") unless plan

      lay[:checkout][:plan].set(plan)
    end
  end

  def reject_duplicate_subscription
    Beryl.task :reject_duplicate_subscription do |lay|
      store = lay[:deps][:store].get
      user = lay[:checkout][:user].get
      existing = store.active_subscription_for_user(user.fetch(:id))

      return lay.reject(:already_subscribed, "user already has an active subscription") if existing

      lay
    end
  end

  def create_charge
    Beryl.task :create_charge do |lay|
      payments = lay[:deps][:payments].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get
      token = lay[:checkout][:payment_token].get

      charge = payments.create_charge(
        user: user,
        plan: plan,
        token: token,
        idempotency_key: "checkout-charge-#{request_id}"
      )

      lay[:checkout][:charge].set(charge)
    end
  end

  def create_subscription
    Beryl.task :create_subscription do |lay|
      store = lay[:deps][:store].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get
      charge = lay[:checkout][:charge].get

      subscription = store.create_subscription(
        user_id: user.fetch(:id),
        plan_id: plan.fetch(:id),
        charge_id: charge.fetch(:id)
      )

      lay[:checkout][:subscription].set(subscription)
    end
  end

  def deliver_receipt
    Beryl.task :deliver_receipt do |lay|
      mailer = lay[:deps][:mailer].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get

      delivery = mailer.deliver_subscription_started(
        email: user.fetch(:email),
        plan_name: plan.fetch(:name),
        request_id: request_id
      )

      lay[:checkout][:mail_delivery].set(delivery)
    end
  end

  def write_success_audit_log
    Beryl.task :write_success_audit_log do |lay|
      store = lay[:deps][:store].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      subscription = lay[:checkout][:subscription].get
      charge = lay[:checkout][:charge].get

      audit_log = store.write_audit_log(
        action: "subscription.started",
        user_id: user.fetch(:id),
        subject_id: subscription.fetch(:id),
        request_id: request_id,
        payload: { charge_id: charge.fetch(:id) }
      )

      lay[:checkout][:audit_log].set(audit_log)
    end
  end

  def capture_exception
    Beryl.task :capture_exception do |lay|
      lay
    end.rescue_with(:capture_exception) do |error, lay|
      lay[:failure].set(
        code: error.code,
        message: error.message,
        failed_node: error.failed_node,
        trace: error.trace
      )
    end
  end

  def copy_failure_to_checkout
    Beryl.task :copy_failure_to_checkout do |lay|
      failure = safe_get(lay, :failure)
      return lay unless failure

      lay[:checkout][:failure].set(failure)
    end
  end

  def refund_charge_if_needed
    Beryl.task :refund_charge_if_needed do |lay|
      charge = safe_get(lay, :checkout, :charge)
      return lay unless charge

      payments = lay[:deps][:payments].get
      request_id = lay[:http][:request_id].get
      refund = payments.refund(
        charge_id: charge.fetch(:id),
        reason: "checkout_failed",
        idempotency_key: "checkout-refund-#{request_id}"
      )

      lay[:checkout][:refund].set(refund)
    end
  end

  def record_failure
    Beryl.task :record_failure do |lay|
      store = lay[:deps][:store].get
      request_id = lay[:http][:request_id].get
      failure = safe_get(lay, :checkout, :failure)
      return lay unless failure

      record = store.record_failure(
        user_id: safe_get(lay, :checkout, :user_id),
        plan_id: safe_get(lay, :checkout, :plan_id),
        request_id: request_id,
        code: failure.fetch(:code),
        message: failure.fetch(:message),
        payload: { refund: safe_get(lay, :checkout, :refund) }
      )

      lay[:checkout][:failure_record].set(record)
    end
  end

  def return_failure
    Beryl.task :return_failure do |lay|
      failure = safe_get(lay, :checkout, :failure)
      return lay unless failure

      lay.reject(failure.fetch(:code).to_sym, failure.fetch(:message).to_s)
    end
  end

  def safe_get(lay, *path)
    path.reduce(lay) { |focus, key| focus[key] }.get
  rescue StandardError
    nil
  end
end

class App < Roda
  plugin :json

  route do |r|
    r.root do
      { ok: true, service: "beryl-checkout" }
    end

    r.on "api" do
      r.post "checkout" do
        request_id = r.env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid

        root = Beryl.root(
          http: {
            request: r,
            request_id: request_id
          },
          deps: {
            store: STORE,
            payments: PAYMENTS,
            mailer: MAILER
          }
        )

        result = CheckoutWorkflow.call(root)

        case result
        in Beryl::Ok(lay)
          response.status = 201
          {
            subscription: lay[:checkout][:subscription].get,
            mail_delivery: lay[:checkout][:mail_delivery].get,
            audit_log: lay[:checkout][:audit_log].get,
            root: root.state
          }
        in Beryl::Err(lay, code, message, _cause)
          response.status = error_status(code)
          {
            error: code,
            message: message,
            refund: safe_get(lay, :checkout, :refund),
            failure_record: safe_get(lay, :checkout, :failure_record),
            root: root.state
          }
        end
      end
    end
  end

  private

  def error_status(code)
    case code
    when :bad_request, :empty_json_body, :invalid_json_body, :invalid_payment_token
      400
    when :user_not_found, :plan_not_found
      404
    when :already_subscribed
      409
    else
      500
    end
  end

  def safe_get(lay, *path)
    path.reduce(lay) { |focus, key| focus[key] }.get
  rescue StandardError
    nil
  end
end
```

The route starts with `Beryl.root(...)`. That matters. The HTTP request, request id, store, payment
adapter, and mailer are not global workflow magic; they are observations attached to the same Root.
Every task receives a Lay view of that Root.

## Error handling

A domain rejection does not need to raise.

```ruby
reject_duplicate_subscription =
  Beryl.task :reject_duplicate_subscription do |lay|
    store = lay[:deps][:store].get
    user = lay[:checkout][:user].get
    existing = store.active_subscription_for_user(user.fetch(:id))

    if existing
      lay.reject(:already_subscribed, "user already has an active subscription")
    else
      lay
    end
  end
```

An exception becomes `Err(partial_lay, error)`. The partial Lay is kept, so compensation can still
see state created before the failure.

```ruby
result = root | (create_charge >> create_subscription)

case result
in Beryl::Err(lay, error)
  error.code
  error.message
  error.failed_node
  error.trace
  error.parallel_errors
  lay.to_h
end
```

`unwrap` is the projection back to ordinary Ruby error space.

```ruby
result = root | (create_charge >> create_subscription)

case result
in Beryl::Ok(lay)
  lay
in Beryl::Err
  result.unwrap
end
```

If the Beryl error wraps an original exception, `unwrap` raises the original exception. If the
failure came from `lay.reject`, `unwrap` raises `Beryl::Error`.

## Parallel execution

`&` runs sibling branches from the same Lay snapshot. The branches do not mutate a shared object.
Their successful results are merged explicitly.

```ruby
hydrate = (load_user & load_plan).reduce(Beryl::Merge.deep)
root | hydrate
```

If multiple branches fail, Beryl returns one `:parallel_failed` error with every branch error
preserved.

```ruby
result = root | ((load_user & load_plan).reduce(Beryl::Merge.deep))

case result
in Beryl::Err(_lay, error)
  if error.code == :parallel_failed
    error.parallel_errors.each do |branch_error|
      warn "#{branch_error.failed_node}: #{branch_error.message}"
    end
  end
end
```

Built-in reducers:

```ruby
Beryl::Merge.deep
Beryl::Merge.keep_left
Beryl::Merge.keep_right
```

## Branching

```ruby
paid_flow =
  Beryl.task :paid_flow do |lay|
    lay[:checkout][:mode].set(:paid)
  end

trial_flow =
  Beryl.task :trial_flow do |lay|
    lay[:checkout][:mode].set(:trial)
  end

choose_plan =
  (Beryl::When[:paid] { |lay| lay[:checkout][:plan].get.fetch(:price_cents).positive? } >> paid_flow) |
  (Beryl::Else >> trial_flow)

root | choose_plan
```

Ruby operator precedence matters. Prefer parentheses around branch arms.

## Comparison

### Plain service object

```ruby
class CheckoutService
  def initialize(store:, payments:, mailer:)
    @store = store
    @payments = payments
    @mailer = mailer
  end

  def call(params, request_id:)
    user_id = Integer(params.fetch("user_id"))
    plan_id = Integer(params.fetch("plan_id"))
    token = params.fetch("payment_token").to_s.strip
    raise ArgumentError, "payment_token is required" if token.empty?

    user = @store.find_user(user_id)
    raise "user #{user_id} not found" unless user

    plan = @store.find_active_plan(plan_id)
    raise "active plan #{plan_id} not found" unless plan

    existing = @store.active_subscription_for_user(user.fetch(:id))
    raise "user already has an active subscription" if existing

    charge = @payments.create_charge(
      user: user,
      plan: plan,
      token: token,
      idempotency_key: "checkout-charge-#{request_id}"
    )

    subscription = @store.create_subscription(
      user_id: user.fetch(:id),
      plan_id: plan.fetch(:id),
      charge_id: charge.fetch(:id)
    )

    delivery = @mailer.deliver_subscription_started(
      email: user.fetch(:email),
      plan_name: plan.fetch(:name),
      request_id: request_id
    )

    audit_log = @store.write_audit_log(
      action: "subscription.started",
      user_id: user.fetch(:id),
      subject_id: subscription.fetch(:id),
      request_id: request_id,
      payload: { charge_id: charge.fetch(:id) }
    )

    {
      subscription: subscription,
      mail_delivery: delivery,
      audit_log: audit_log
    }
  rescue StandardError => error
    if defined?(charge) && charge
      refund = @payments.refund(
        charge_id: charge.fetch(:id),
        reason: "checkout_failed",
        idempotency_key: "checkout-refund-#{request_id}"
      )
    end

    @store.record_failure(
      user_id: defined?(user_id) ? user_id : nil,
      plan_id: defined?(plan_id) ? plan_id : nil,
      request_id: request_id,
      code: error.class.name,
      message: error.message,
      payload: { refund: refund }
    )

    raise
  end
end
```

This works, but the graph is implicit. Parallelizable steps, compensation boundaries, partial state,
and failure taxonomy live inside local variables and rescue scope.

### Beryl workflow

```ruby
root = Beryl.root(
  http: { request: request, request_id: request_id },
  deps: { store: store, payments: payments, mailer: mailer }
)

result = root | CheckoutWorkflow.node
```

With Beryl, the graph is a value:

```ruby
CheckoutWorkflow.checkout
# read_json_body >> normalize_input >>
# (load_user & load_plan).reduce(Beryl::Merge.deep) >>
# reject_duplicate_subscription >> create_charge >> create_subscription >>
# (deliver_receipt & write_success_audit_log).reduce(Beryl::Merge.deep)
```

The difference is not that Beryl uses fewer lines. The difference is that the operational shape is
explicit:

| Concern                    | Service object                     | Beryl                                                  |
| -------------------------- | ---------------------------------- | ------------------------------------------------------ |
| Boundary state             | constructor args + params + locals | one `Root`                                             |
| Task state access          | local variables                    | `Lay` observation                                      |
| Sequence                   | method body order                  | `a >> b`                                               |
| Parallelizable work        | hidden unless manually threaded    | `a & b`                                                |
| Compensation               | broad `rescue` with locals         | `flow.rescue_with(handler)` over partial Lay           |
| Domain failure             | exceptions or ad-hoc return values | `lay.reject(:code, "message")`                         |
| Error envelope             | exception class/message            | `Beryl::Error` with code, node, trace, parallel errors |
| Ordinary Ruby escape hatch | already ordinary exceptions        | `Err#unwrap`                                           |
| Inspectable graph          | no                                 | yes, workflow node value                               |

### dry-transaction / Interactor / Trailblazer style

Beryl is closer to these than to Rails callbacks, but it does not ask you to declare input/output
contracts in a DSL. A task body is just Ruby over Lay.

```ruby
load_user =
  Beryl.task :load_user do |lay|
    user = lay[:deps][:store].get.find_user(lay[:checkout][:user_id].get)
    user ? lay[:checkout][:user].set(user) : lay.reject(:user_not_found, "user not found")
  end
```

The reason to use Beryl is the root-core shape: one entity at the boundary, multiple observations
through Lay, named computations over that observation, and explicit algebra for sequence / parallel
/ branch / rescue.

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
