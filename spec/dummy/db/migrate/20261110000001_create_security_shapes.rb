# Table shapes common in host apps that the security specs must cover (T31a): single table inheritance, soft-delete, a nullable
# tenant column and a nullable key on the way to the tenant. Never exposed to DataTeller in config/data_teller: the classes are
# defined in the specs, so the evaluation catalog (ADR 0006 D1) and its measures stay as they are.
class CreateSecurityShapes < ActiveRecord::Migration[7.2]
  def change
    # STI: `type` holds the subclass. deleted_at for the soft-delete cases, read through a default_scope in the specs.
    create_table :security_payments do |t|
      t.string :type, null: false
      t.references :order, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.datetime :deleted_at
      t.timestamps
    end

    # Reaches the tenant through a payment, so through an STI subclass when the spec says so. The payment is optional:
    # a dispute without one belongs to no tenant.
    create_table :security_disputes do |t|
      t.references :security_payment, foreign_key: true
      t.integer :amount_cents, null: false
      t.timestamps
    end

    # A tenant column that can be NULL: rows shared by everyone in some apps, rows belonging to no tenant here.
    create_table :security_notes do |t|
      t.references :account, foreign_key: true
      t.integer :value, null: false
      t.timestamps
    end
  end
end
