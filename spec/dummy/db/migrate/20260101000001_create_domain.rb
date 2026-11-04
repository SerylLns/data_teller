class CreateDomain < ActiveRecord::Migration[7.2]
  def change
    create_table :accounts do |t|
      t.string :name, null: false
      t.string :time_zone, null: false, default: "UTC"
      t.timestamps
    end

    create_table :customers do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false # sensitive on purpose: exercises hidden-column inference
      t.string :phone
      t.string :city
      t.timestamps
    end

    create_table :products do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :category, null: false
      t.integer :price_cents, null: false
      t.timestamps
    end

    create_table :orders do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.datetime :ordered_at, null: false
      t.date :ship_on
      t.timestamps
    end
    add_index :orders, %i[account_id status ship_on]

    # No account_id on purpose: tenant is reached through order, as in many real schemas.
    create_table :line_items do |t|
      t.references :order, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.integer :unit_price_cents, null: false
      t.timestamps
    end

    create_table :shipments do |t|
      t.references :order, null: false, foreign_key: true
      t.string :carrier, null: false
      t.datetime :shipped_at
      t.date :delivered_on
      t.timestamps
    end
  end
end
