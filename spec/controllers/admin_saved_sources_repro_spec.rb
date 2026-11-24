# frozen_string_literal: true

require "solidus_stripe_spec_helper"

RSpec.describe Spree::Admin::PaymentsController, type: :controller do
  routes { Spree::Core::Engine.routes }
  stub_authorization!
  render_views

  let(:payment_method) { create(:solidus_stripe_payment_method) }
  let(:user) { create(:user) }
  let(:source) { create(:solidus_stripe_payment_source, payment_method: payment_method) }
  let(:order) { create(:order_with_line_items, user: user, state: "payment") }

  before do
    user.wallet.add(source)
    allow(Stripe::PaymentMethod).to receive(:retrieve) do |id|
      Stripe::PaymentMethod.construct_from(
        id: id,
        type: "card",
        card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2030 }
      )
    end
    allow(controller).to receive(:spree_current_user).and_return(create(:admin_user))
  end

  it "lists the saved Stripe source on the new payment form" do
    get :new, params: { order_id: order.number }

    expect(response.body).to match(/<input[^>]*name="card"[^>]*value="#{source.id}"/)
  end

  it "reports reusable_sources for the saved Stripe source" do
    expect(payment_method.reusable_sources(order)).to eq([source])
  end

  it "accepts the saved Stripe source when creating a payment" do
    post :create, params: {
      order_id: order.number,
      payment: { payment_method_id: payment_method.id, amount: order.total },
      card: source.id
    }

    expect(order.payments.reload.map(&:source)).to eq([source])
  end
end
