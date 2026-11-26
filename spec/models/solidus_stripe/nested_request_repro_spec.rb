# frozen_string_literal: true

require "solidus_stripe_spec_helper"

RSpec.describe SolidusStripe::PaymentIntent do
  let(:payment_method) { create(:solidus_stripe_payment_method) }
  let(:order) { create(:order_with_line_items, state: "payment") }
  let(:stripe_intents) { {} }

  before do
    allow(Stripe::PaymentMethod).to receive(:retrieve) do |id|
      Stripe::PaymentMethod.construct_from(id: id, type: "card")
    end
    allow(Stripe::Customer).to receive(:create) { Stripe::Customer.construct_from(id: "cus_123") }
    allow(Stripe::PaymentIntent).to receive(:create) do |params|
      stripe_intents["pi_new"] = Stripe::PaymentIntent.construct_from(
        id: "pi_new", amount: params[:amount], status: "requires_payment_method"
      )
    end
    allow(Stripe::PaymentIntent).to receive(:retrieve) { |id| stripe_intents.fetch(id) }
    allow(Stripe::PaymentIntent).to receive(:update) { |id, _params| stripe_intents.fetch(id) }
  end

  it "prepares an intent for a payment whose source was built with the payment method object" do
    source = SolidusStripe::PaymentSource.create!(payment_method: payment_method, stripe_payment_method_id: "pm_123")
    payment = order.payments.create!(payment_method: payment_method, amount: order.total, source: source)

    expect { described_class.prepare_for_payment(payment) }.not_to raise_error
  end

  it "creates the intent when the source holds the same PaymentMethod instance as the payment" do
    payment = create(:solidus_stripe_payment, order: order, payment_method: payment_method)

    expect(payment.source.payment_method).to equal(payment.payment_method)
    expect { described_class.create_for_payment(payment) }.not_to raise_error
  end

  it "creates the intent when the payment is reloaded so the source loads its own PaymentMethod" do
    payment = Spree::Payment.find(create(:solidus_stripe_payment, order: order, payment_method: payment_method).id)

    expect(payment.source.payment_method).not_to equal(payment.payment_method)
    expect { described_class.create_for_payment(payment) }.not_to raise_error
  end

  it "updates an existing intent when the source holds the same PaymentMethod instance as the payment" do
    payment = create(:solidus_stripe_payment, order: order, payment_method: payment_method)
    intent = create(:solidus_stripe_payment_intent, order: order, payment_method: payment_method, stripe_intent_id: "pi_old")
    stripe_intents["pi_old"] = Stripe::PaymentIntent.construct_from(
      id: "pi_old", amount: intent.stripe_order_amount, status: "requires_payment_method"
    )

    expect { described_class.retrieve_for_payment(payment) }.not_to raise_error
  end
end
