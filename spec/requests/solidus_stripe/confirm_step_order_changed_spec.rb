# frozen_string_literal: true

require "solidus_stripe_spec_helper"

RSpec.describe "Placing an order on the confirm step after the order changed", type: :request do
  let(:payment_method) { create(:solidus_stripe_payment_method) }
  let(:order) { create(:order_with_line_items, state: "confirm") }
  let!(:payment) { create(:solidus_stripe_payment, order: order, payment_method: payment_method) }
  let!(:intent) do
    create(
      :solidus_stripe_payment_intent,
      order: order,
      payment_method: payment_method,
      stripe_intent_id: payment.response_code
    )
  end
  let(:stripe_intents) { {} }

  before do
    sign_in order.user

    allow(Stripe::PaymentIntent).to receive(:retrieve) { |id| stripe_intents.fetch(id) }
    allow(Stripe::PaymentIntent).to receive(:create) do |params|
      stripe_intents["pi_second"] =
        Stripe::PaymentIntent.construct_from(
          id: "pi_second",
          amount: params[:amount],
          status: "requires_confirmation",
          client_secret: "pi_second_secret"
        )
    end
    allow(Stripe::PaymentMethod).to receive(:retrieve) do |id|
      Stripe::PaymentMethod.construct_from(
        id: id,
        type: "card",
        card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2030 }
      )
    end
    allow(Stripe::Customer).to receive(:create) { Stripe::Customer.construct_from(id: "cus_123") }
    allow(Stripe::PaymentIntent).to receive(:cancel)
    allow(Stripe::Refund).to receive(:create)
  end

  def stripe_charged(amount)
    stripe_intents[intent.stripe_intent_id] = Stripe::PaymentIntent.construct_from(
      id: intent.stripe_intent_id,
      amount: amount,
      status: "succeeded",
      setup_future_usage: nil
    )
  end

  def place_order
    get "/solidus_stripe/#{payment_method.slug}/after_confirmation", params: { payment_intent: intent.stripe_intent_id }
  end

  def with_production_error_pages
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :all
    yield
  ensure
    env_config["action_dispatch.show_exceptions"] = original
  end

  it "does not keep the payment when an item sells out after the confirm page loaded" do
    stripe_charged(intent.stripe_order_amount)
    order.line_items.first.variant.stock_items.update_all(count_on_hand: 0, backorderable: false)

    with_production_error_pages { place_order }

    expect(order.reload).not_to be_completed
    expect(payment.reload.state).not_to eq("completed")
  end

  it "does not charge the full total again after the cart changed in another tab" do
    amount_charged = intent.stripe_order_amount
    stripe_charged(amount_charged)
    order.contents.add(create(:variant), 1)

    place_order

    order.reload.next! until order.payment?
    new_payment = create(:solidus_stripe_payment, order: order, payment_method: payment_method, response_code: nil)
    order.next!
    new_payment.source.stripe_payment_method
    second_intent = SolidusStripe::PaymentIntent.prepare_for_payment(new_payment)

    expect(amount_charged + second_intent.stripe_intent.amount).to eq(second_intent.stripe_order_amount)
  end

  it "does not complete the order for less than its total when a tax rate starts applying mid-checkout" do
    stripe_charged(intent.stripe_order_amount)
    create(
      :tax_rate,
      amount: 0.1,
      zone: create(:zone, countries: [order.tax_address.country]),
      tax_categories: [order.line_items.first.tax_category]
    )

    place_order

    expect([order.reload.state, order.payment_state]).not_to eq(["complete", "balance_due"])
  end
end
