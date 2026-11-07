# The domain the evaluation runs on (ADR 0006 D1): enough datasets, and names close enough to each other, for an LLM to get
# them wrong and for retrieval to have something to retrieve.
class GrowShopDomain < ActiveRecord::Migration[7.2]
  def change
    change_table :customers do |t|
      t.integer :acquisition_channel, null: false, default: 0
      t.integer :tier, null: false, default: 0
      t.date :signed_up_on
    end

    change_table :products do |t|
      t.boolean :active, null: false, default: true
      t.date :launched_on
    end

    create_table :coupons do |t|
      t.references :account, null: false, foreign_key: true
      t.string :code, null: false
      t.integer :kind, null: false, default: 0
      t.integer :value, null: false, default: 0 # a percentage, or cents for a fixed discount
      t.date :starts_on, null: false
      t.date :ends_on
      t.timestamps
    end

    # total_cents is what the customer paid, after the discount; net_total_cents is that minus refunds.
    change_table :orders do |t|
      t.references :coupon, foreign_key: true
      t.integer :channel, null: false, default: 0
      t.integer :discount_cents, null: false, default: 0
      t.integer :net_total_cents, null: false, default: 0
    end

    add_column :shipments, :cost_cents, :integer, null: false, default: 0

    # No account_id: the tenant is reached through the order, like line items and shipments.
    create_table :refunds do |t|
      t.references :order, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.integer :reason, null: false, default: 0
      t.datetime :refunded_at, null: false
      t.timestamps
    end

    create_table :subscriptions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.integer :plan, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.integer :mrr_cents, null: false, default: 0
      t.date :started_on, null: false
      t.date :cancelled_on
      t.timestamps
    end

    create_table :invoices do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :subscription, foreign_key: true
      t.string :number, null: false
      t.integer :status, null: false, default: 0
      t.integer :amount_cents, null: false
      t.date :issued_on, null: false
      t.date :due_on, null: false
      t.datetime :paid_at
      t.timestamps
    end

    create_table :support_tickets do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :order, foreign_key: true
      t.integer :channel, null: false, default: 0
      t.integer :priority, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.datetime :opened_at, null: false
      t.datetime :resolved_at
      t.integer :resolution_minutes
      t.integer :satisfaction # 1 to 5, when the customer answered the survey
      t.timestamps
    end

    # No account_id: the tenant is reached through the product.
    create_table :reviews do |t|
      t.references :product, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.integer :rating, null: false
      t.boolean :verified, null: false, default: false
      t.date :published_on, null: false
      t.timestamps
    end
  end
end
