# beryl

A Ruby-native workflow gem for composing tasks inside a Lay-lifted state space.

Beryl is not an IO/effect system and not a replacement for Rails. It is a small algebraic layer for
business workflows: the flow starts by lifting Lay into State, tasks transform that state space, and
control shapes such as sequence, parallel, branch, and rescue are explicit nodes instead of hidden
service object control flow.

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

state = Beryl::State[name: "  mina  "]

result =
  state |
  (Beryl.task :strip do |lay|
    lay[:name].update(&:strip)
  end) |
  (Beryl.task :greet do |lay|
    lay[:greeting].set("hello #{lay[:name].get}")
  end)
# => Beryl::Ok(lay)

result.focus.to_h
# => { name: "mina", greeting: "hello mina" }
```

The public surface is intentionally small:

- `State[...]` lifts an initial Lay into the state-flow space
- `state | (task :name do |lay| ... end)` appends and runs a named task inside that space
- `Lay[...]` remains the focused state representation under State
- `Flow[lay].call(workflow_or_node)` is the lower-level runner
- `Task[:name] { |root| ... }` is the lower-level named task constructor
- `Workflow[:name] { ... }` names an inspectable node graph
- `a >> b` for sequential execution
- `a & b` for promise-like parallel execution
- `(When[:case] { ... } >> task) | (Else >> fallback)` for branch / else
- `flow.rescue_with(handler_task)` or `flow.rescue_with(:name) { |error, root| ... }`
- `Ok(lay)` / `Err(lay, code, message, cause)` as explicit results

No `Effect`, no `reads`, no `writes`, no `requires`, no `returns`, no `Task / lens` outer syntax.
The flow starts by lifting Lay into State. After that, `state | (task :name do |lay| ... end)`
composes inside the State-monad-like space. Task bodies receive the Lay root and access state inside
the block.

## Tiny HTTP app example: Roda checkout workflow

Rails is not the target here. A better fit is a Hono-like Ruby app: thin router, plain dependencies,
explicit workflow. The route builds `State[...]` first, which lifts the initial Lay into Beryl. The
workflow does not receive `params`; tasks receive the Lay root inside State.

Full application code is in [`examples/roda_checkout_app.rb`](examples/roda_checkout_app.rb). It
includes schema setup, seed data, a fake payment adapter, a fake mailer, the HTTP route, and every
workflow task definition.

The route starts by lifting Lay into State:

```ruby
class App < Roda
  plugin :json

  route do |r|
    r.on "api" do
      r.post "checkout" do
        request_id = r.env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid

        state =
          Beryl::State[
            http: {
              request: r,
              request_id: request_id
            },
            deps: {
              db: DB,
              payments: Payments,
              mailer: Mailer
            }
          ]

        result = CheckoutWorkflow.call(state)

        case result
        in Beryl::Ok(focus)
          response.status = 201
          {
            subscription: focus[:checkout][:subscription].get,
            mail_delivery: focus[:checkout][:mail_delivery].get,
            audit_log_id: focus[:checkout][:audit_log_id].get
          }
        in Beryl::Err(focus, code, message, _cause)
          response.status = error_status(code)
          { error: code, message: message, refund: safe_get(focus, :checkout, :refund) }
        end
      end
    end
  end
end
```

The request parsing is not an abstract placeholder. It is just another task inside State:

```ruby
read_json_body =
  Beryl.task(:read_json_body) do |lay|
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

normalize_input =
  Beryl.task(:normalize_input) do |lay|
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
```

The full checkout graph is visible as a value:

```ruby
checkout =
  Beryl::Workflow[:checkout] do
    require_lay >>
      read_json_body >>
      normalize_input >>
      (load_user & load_plan).reduce(Beryl::Merge.deep) >>
      reject_duplicate_subscription >>
      create_charge >>
      create_subscription >>
      (deliver_receipt & write_success_audit_log).reduce(Beryl::Merge.deep)
  end

safe_checkout =
  checkout.body.rescue_with(:capture_exception) do |error, lay|
    lay[:failure].set(code: error.class.name, message: error.message)
  end >> capture_failure >> refund_charge_if_needed >> record_failure >> return_failure

def call(state)
  state.call(safe_checkout)
end
```

The important point is not the router or the database library. The important point is the shape:
`State[...]` is constructed at the HTTP boundary, which lifts the initial Lay into the flow space.
All state access still goes through Lay inside task bodies, horizontal work is written with `&`,
compensation is explicit, and the route remains tiny.

```ruby
graph = checkout.compile

graph.nodes
# => [:require_lay, :read_json_body, :normalize_input, :load_user, :load_plan,
#     :reject_duplicate_subscription, :create_charge, :create_subscription,
#     :deliver_receipt, :write_success_audit_log]

graph.parallel_nodes
# => [[:load_user, :load_plan], [:deliver_receipt, :write_success_audit_log]]
```

## Error rescue syntax

Use a task when compensation is also a named workflow node.

```ruby
charge = Beryl.task(:charge) do |lay|
  payment = lay[:deps][:payments].get.charge(token: lay[:checkout][:payment_token].get)
  lay[:checkout][:payment].set(payment)
end

create_subscription = Beryl.task(:create_subscription) do |lay|
  subscription = lay[:deps][:repo].get.create_subscription!(payment: lay[:checkout][:payment].get)
  lay[:checkout][:subscription].set(subscription)
end

refund = Beryl.task(:refund) do |lay|
  lay[:deps][:payments].get.refund(payment_id: lay[:checkout][:payment].get.fetch(:id))
  lay[:checkout][:refunded].set(true)
end

state = Beryl::State[checkout: { payment_token: "tok_live" }, deps: { payments: Payments, repo: Repo }]

flow = (charge >> create_subscription).rescue_with(refund)

state.call(flow)
```

Use a block when the rescue is local and small.

```ruby
flow =
  (charge >> create_subscription).rescue_with(:mark_failed) do |error, root|
    root[:failure].set(error.message)
  end
```

A task exception becomes `Err(partial_lay, code, message, cause)`. Rescue receives the partial Lay
focus, so compensation can still see state produced before the failure.

## Parallel execution syntax

`&` means promise-like horizontal execution. Each branch receives the same Lay snapshot. The parent
combines successful branch focuses with an explicit reducer.

```ruby
load_user = Beryl.task(:load_user) { |root| root[:user].set(User.find(root[:user_id].get)) }
load_plan = Beryl.task(:load_plan) { |root| root[:plan].set(Plan.find(root[:plan_id].get)) }

hydrate = (load_user & load_plan).reduce(Beryl::Merge.deep)

Beryl::State[user_id: 1, plan_id: 3].call(hydrate)
```

Parallel branches do not share a mutable focus. They run independently from the same Lay snapshot
and return their own focuses. If any branch returns `Err`, the parallel node returns that error. If
all branches return `Ok`, the reducer combines them.

Built-in reducers:

```ruby
Beryl::Merge.deep       # deep merge focus hashes
Beryl::Merge.keep_left  # keep accumulated parent focus
Beryl::Merge.keep_right # keep the latest branch focus
```

## Branch and else syntax

Use `When >> task` arms joined by `|`. Use `Else` as the final fallback.

```ruby
paid_flow = Beryl.task(:paid_flow) { |root| root[:status].set(:paid) }
trial_flow = Beryl.task(:trial_flow) { |root| root[:status].set(:trial) }

choose_plan =
  (Beryl::When[:paid] { |root| root[:plan].get == :paid } >> paid_flow) |
  (Beryl::Else >> trial_flow)

Beryl::State[plan: :paid].call(choose_plan)
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

- State-origin flow execution
- task sequencing over Lay focus
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
