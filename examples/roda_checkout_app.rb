# frozen_string_literal: true

# A full Hono-like Ruby HTTP application using Roda + Rack + Sequel.
#
# This is intentionally not Rails. The app surface is a tiny router; Berylx only
# describes the business flow. Persistence, payment, and mail delivery are plain
# Ruby dependencies carried by Lay.
#
# Run shape, if you add these gems to a small app:
#   gem "roda"
#   gem "sequel"
#   gem "sqlite3"
#   gem "berylx"
#
#   rackup examples/config.ru

require 'json'
require 'securerandom'
require 'time'
require 'roda'
require 'sequel'
require 'berylx'

DATABASE_URL = ENV.fetch('DATABASE_URL', 'sqlite://db/development.sqlite3')
DB = Sequel.connect(DATABASE_URL)

module Schema
  module_function

  def migrate!(db)
    create_users(db)
    create_plans(db)
    create_subscriptions(db)
    create_audit_logs(db)
    create_checkout_failures(db)
    seed!(db)
  end

  def create_users(db)
    return if db.table_exists?(:users)

    db.create_table(:users) do
      primary_key :id
      String :email, null: false
      String :name, null: false
      Time :created_at, null: false
    end
  end

  def create_plans(db)
    return if db.table_exists?(:plans)

    db.create_table(:plans) do
      primary_key :id
      String :name, null: false
      Integer :price_cents, null: false
      TrueClass :active, null: false, default: true
      Time :created_at, null: false
    end
  end

  def create_subscriptions(db)
    return if db.table_exists?(:subscriptions)

    db.create_table(:subscriptions) do
      primary_key :id
      Integer :user_id, null: false
      Integer :plan_id, null: false
      String :charge_id, null: false
      String :status, null: false
      Time :created_at, null: false
    end
  end

  def create_audit_logs(db)
    return if db.table_exists?(:audit_logs)

    db.create_table(:audit_logs) do
      primary_key :id
      String :action, null: false
      Integer :user_id
      Integer :subject_id
      String :request_id
      String :payload_json, text: true
      Time :created_at, null: false
    end
  end

  def create_checkout_failures(db)
    return if db.table_exists?(:checkout_failures)

    db.create_table(:checkout_failures) do
      primary_key :id
      Integer :user_id
      Integer :plan_id
      String :request_id
      String :code, null: false
      String :message, text: true
      String :payload_json, text: true
      Time :created_at, null: false
    end
  end

  def seed!(db)
    now = Time.now

    db[:users].insert(email: 'mina@example.com', name: 'Mina', created_at: now) if db[:users].empty?

    return unless db[:plans].empty?

    db[:plans].multi_insert([
                              { name: 'Starter', price_cents: 1_200, active: true, created_at: now },
                              { name: 'Pro', price_cents: 4_800, active: true, created_at: now },
                              { name: 'Legacy', price_cents: 900, active: false, created_at: now }
                            ])
  end
end

module Payments
  module_function

  def create_charge(user:, plan:, token:, idempotency_key:)
    raise PaymentDeclined, 'card was declined' if token == 'tok_declined'

    {
      id: "ch_#{SecureRandom.hex(8)}",
      idempotency_key: idempotency_key,
      user_id: user.fetch(:id),
      plan_id: plan.fetch(:id),
      amount: plan.fetch(:price_cents),
      token_last4: token[-4, 4],
      status: 'succeeded',
      created_at: Time.now.iso8601
    }
  end

  def refund(charge_id:, reason:, idempotency_key:)
    {
      id: "rf_#{SecureRandom.hex(8)}",
      charge_id: charge_id,
      reason: reason,
      idempotency_key: idempotency_key,
      status: 'refunded',
      created_at: Time.now.iso8601
    }
  end

  class PaymentDeclined < StandardError; end
end

module Mailer
  module_function

  def deliver_subscription_started(email:, plan_name:, request_id:)
    {
      id: "mail_#{SecureRandom.hex(8)}",
      to: email,
      template: 'subscription_started',
      plan_name: plan_name,
      request_id: request_id,
      queued: true
    }
  end
end

module CheckoutWorkflow
  module_function

  require_lay =
    Berylx::Task[:require_lay] do |lay|
      next lay.reject(:missing_http_request, 'lay[:http][:request] is required') unless lay[:http][:request].get
      next lay.reject(:missing_db, 'lay[:deps][:db] is required') unless lay[:deps][:db].get
      next lay.reject(:missing_payments, 'lay[:deps][:payments] is required') unless lay[:deps][:payments].get
      next lay.reject(:missing_mailer, 'lay[:deps][:mailer] is required') unless lay[:deps][:mailer].get

      lay
    rescue KeyError => e
      lay.reject(:invalid_lay, e.message, cause: e)
    end

  read_json_body =
    Berylx::Task[:read_json_body] do |lay|
      request = lay[:http][:request].get
      body = request.body.read
      request.body.rewind if request.body.respond_to?(:rewind)

      next lay.reject(:empty_json_body, 'request body is empty') if body.strip.empty?

      json = JSON.parse(body)
      next lay.reject(:invalid_json_body, 'JSON body must be an object') unless json.is_a?(Hash)

      lay[:input].set(json)
    rescue JSON::ParserError => e
      lay.reject(:invalid_json_body, e.message, cause: e)
    end

  normalize_input =
    Berylx::Task[:normalize_input] do |lay|
      input = lay[:input].get

      user_id = Integer(input.fetch('user_id'))
      plan_id = Integer(input.fetch('plan_id'))
      payment_token = input.fetch('payment_token').to_s.strip

      next lay.reject(:invalid_payment_token, 'payment_token is required') if payment_token.empty?

      lay = lay[:checkout][:user_id].set(user_id)
      lay = lay[:checkout][:plan_id].set(plan_id)
      lay[:checkout][:payment_token].set(payment_token)
    rescue KeyError, ArgumentError => e
      lay.reject(:bad_request, e.message, cause: e)
    end

  load_user =
    Berylx::Task[:load_user] do |lay|
      db = lay[:deps][:db].get
      user_id = lay[:checkout][:user_id].get
      user = db[:users].where(id: user_id).first

      next lay.reject(:user_not_found, "user #{user_id} not found") unless user

      lay[:checkout][:user].set(user)
    end

  load_plan =
    Berylx::Task[:load_plan] do |lay|
      db = lay[:deps][:db].get
      plan_id = lay[:checkout][:plan_id].get
      plan = db[:plans].where(id: plan_id, active: true).first

      next lay.reject(:plan_not_found, "active plan #{plan_id} not found") unless plan

      lay[:checkout][:plan].set(plan)
    end

  reject_duplicate_subscription =
    Berylx::Task[:reject_duplicate_subscription] do |lay|
      db = lay[:deps][:db].get
      user = lay[:checkout][:user].get
      existing = db[:subscriptions].where(user_id: user.fetch(:id), status: 'active').first

      next lay.reject(:already_subscribed, 'user already has an active subscription') if existing

      lay
    end

  create_charge =
    Berylx::Task[:create_charge] do |lay|
      payments = lay[:deps][:payments].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get
      token = lay[:checkout][:payment_token].get

      charge =
        payments.create_charge(
          user: user,
          plan: plan,
          token: token,
          idempotency_key: "checkout-charge-#{request_id}"
        )

      lay[:checkout][:charge].set(charge)
    end

  create_subscription =
    Berylx::Task[:create_subscription] do |lay|
      db = lay[:deps][:db].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get
      charge = lay[:checkout][:charge].get

      subscription =
        db.transaction do
          subscription_id =
            db[:subscriptions].insert(
              user_id: user.fetch(:id),
              plan_id: plan.fetch(:id),
              charge_id: charge.fetch(:id),
              status: 'active',
              created_at: Time.now
            )

          db[:subscriptions].where(id: subscription_id).first
        end

      lay[:checkout][:subscription].set(subscription)
    end

  deliver_receipt =
    Berylx::Task[:deliver_receipt] do |lay|
      mailer = lay[:deps][:mailer].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      plan = lay[:checkout][:plan].get

      delivery =
        mailer.deliver_subscription_started(
          email: user.fetch(:email),
          plan_name: plan.fetch(:name),
          request_id: request_id
        )

      lay[:checkout][:mail_delivery].set(delivery)
    end

  write_success_audit_log =
    Berylx::Task[:write_success_audit_log] do |lay|
      db = lay[:deps][:db].get
      request_id = lay[:http][:request_id].get
      user = lay[:checkout][:user].get
      subscription = lay[:checkout][:subscription].get
      charge = lay[:checkout][:charge].get

      audit_id =
        db[:audit_logs].insert(
          action: 'subscription.started',
          user_id: user.fetch(:id),
          subject_id: subscription.fetch(:id),
          request_id: request_id,
          payload_json: JSON.generate(charge_id: charge.fetch(:id)),
          created_at: Time.now
        )

      lay[:checkout][:audit_log_id].set(audit_id)
    end

  capture_failure =
    Berylx::Task[:capture_failure] do |lay|
      failure = lay[:failure].get
      next lay unless failure

      lay[:checkout][:failure].set(failure)
    rescue KeyError
      lay
    end

  refund_charge_if_needed =
    Berylx::Task[:refund_charge_if_needed] do |lay|
      charge = lay[:checkout][:charge].get
      next lay unless charge

      payments = lay[:deps][:payments].get
      request_id = lay[:http][:request_id].get
      refund =
        payments.refund(
          charge_id: charge.fetch(:id),
          reason: 'checkout_failed',
          idempotency_key: "checkout-refund-#{request_id}"
        )

      lay[:checkout][:refund].set(refund)
    rescue KeyError
      lay
    end

  record_failure =
    Berylx::Task[:record_failure] do |lay|
      db = lay[:deps][:db].get
      request_id = lay[:http][:request_id].get
      failure = lay[:checkout][:failure].get

      db[:checkout_failures].insert(
        user_id: safe_get(lay, :checkout, :user_id),
        plan_id: safe_get(lay, :checkout, :plan_id),
        request_id: request_id,
        code: failure.fetch(:code).to_s,
        message: failure.fetch(:message).to_s,
        payload_json: JSON.generate(refund: safe_get(lay, :checkout, :refund)),
        created_at: Time.now
      )

      lay
    rescue StandardError
      lay
    end

  return_failure =
    Berylx::Task[:return_failure] do |lay|
      failure = lay[:checkout][:failure].get
      lay.reject(failure.fetch(:code).to_sym, failure.fetch(:message).to_s)
    rescue KeyError => e
      lay.reject(:checkout_failed, 'checkout failed', cause: e)
    end

  checkout =
    Berylx::Workflow[:checkout] do
      require_lay >>
        read_json_body >>
        normalize_input >>
        (load_user & load_plan).reduce(Berylx::Merge.deep) >>
        reject_duplicate_subscription >>
        create_charge >>
        create_subscription >>
        (deliver_receipt & write_success_audit_log).reduce(Berylx::Merge.deep)
    end

  checkout.body.rescue_with(:capture_exception) do |error, lay|
    lay[:failure].set(code: error.class.name, message: error.message)
  end >> capture_failure >> refund_charge_if_needed >> record_failure >> return_failure

  def node
    safe_checkout
  end

  def call(state)
    state.call(node)
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
      { ok: true, service: 'berylx-roda-checkout' }
    end

    r.on 'api' do
      r.post 'checkout' do
        request_id = r.env['HTTP_X_REQUEST_ID'] || SecureRandom.uuid

        state =
          Berylx::State[
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
        in Berylx::Ok(focus)
          response.status = 201
          {
            subscription: focus[:checkout][:subscription].get,
            mail_delivery: focus[:checkout][:mail_delivery].get,
            audit_log_id: focus[:checkout][:audit_log_id].get
          }
        in Berylx::Err(focus, code, message, _cause)
          response.status = error_status(code)
          {
            error: code,
            message: message,
            refund: safe_get(focus, :checkout, :refund)
          }
        end
      end
    end
  end

  private

  def error_status(code)
    case code
    when :bad_request, :empty_json_body, :invalid_json_body, :invalid_payment_token, :invalid_lay
      400
    when :user_not_found, :plan_not_found
      404
    when :already_subscribed
      409
    else
      500
    end
  end

  def safe_get(focus, *path)
    path.reduce(focus) { |acc, key| acc[key] }.get
  rescue StandardError
    nil
  end
end

Schema.migrate!(DB) if ENV['BERYL_EXAMPLE_MIGRATE'] == '1'
