# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_10_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "unaccent"
  enable_extension "vector"

  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
    t.string "time_zone", default: "UTC", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "coupons", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "code", null: false
    t.integer "kind", default: 0, null: false
    t.integer "value", default: 0, null: false
    t.date "starts_on", null: false
    t.date "ends_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_coupons_on_account_id"
  end

  create_table "customers", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "phone"
    t.string "city"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "acquisition_channel", default: 0, null: false
    t.integer "tier", default: 0, null: false
    t.date "signed_up_on"
    t.index ["account_id"], name: "index_customers_on_account_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "subscription_id"
    t.string "number", null: false
    t.integer "status", default: 0, null: false
    t.integer "amount_cents", null: false
    t.date "issued_on", null: false
    t.date "due_on", null: false
    t.datetime "paid_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoices_on_account_id"
    t.index ["customer_id"], name: "index_invoices_on_customer_id"
    t.index ["subscription_id"], name: "index_invoices_on_subscription_id"
  end

  create_table "line_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", null: false
    t.integer "unit_price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_line_items_on_order_id"
    t.index ["product_id"], name: "index_line_items_on_product_id"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "customer_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "total_cents", default: 0, null: false
    t.datetime "ordered_at", null: false
    t.date "ship_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "coupon_id"
    t.integer "channel", default: 0, null: false
    t.integer "discount_cents", default: 0, null: false
    t.integer "net_total_cents", default: 0, null: false
    t.index ["account_id", "status", "ship_on"], name: "index_orders_on_account_id_and_status_and_ship_on"
    t.index ["account_id"], name: "index_orders_on_account_id"
    t.index ["coupon_id"], name: "index_orders_on_coupon_id"
    t.index ["customer_id"], name: "index_orders_on_customer_id"
  end

  create_table "products", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "category", null: false
    t.integer "price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.date "launched_on"
    t.index ["account_id"], name: "index_products_on_account_id"
  end

  create_table "refunds", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.integer "amount_cents", null: false
    t.integer "reason", default: 0, null: false
    t.datetime "refunded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_refunds_on_order_id"
  end

  create_table "reviews", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "customer_id", null: false
    t.integer "rating", null: false
    t.boolean "verified", default: false, null: false
    t.date "published_on", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_reviews_on_customer_id"
    t.index ["product_id"], name: "index_reviews_on_product_id"
  end

  create_table "security_disputes", force: :cascade do |t|
    t.bigint "security_payment_id"
    t.integer "amount_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["security_payment_id"], name: "index_security_disputes_on_security_payment_id"
  end

  create_table "security_notes", force: :cascade do |t|
    t.bigint "account_id"
    t.integer "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_security_notes_on_account_id"
  end

  create_table "security_payments", force: :cascade do |t|
    t.string "type", null: false
    t.bigint "order_id", null: false
    t.integer "amount_cents", null: false
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_security_payments_on_order_id"
  end

  create_table "shipments", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.string "carrier", null: false
    t.datetime "shipped_at"
    t.date "delivered_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "cost_cents", default: 0, null: false
    t.index ["order_id"], name: "index_shipments_on_order_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "customer_id", null: false
    t.integer "plan", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.integer "mrr_cents", default: 0, null: false
    t.date "started_on", null: false
    t.date "cancelled_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_subscriptions_on_account_id"
    t.index ["customer_id"], name: "index_subscriptions_on_customer_id"
  end

  create_table "support_tickets", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "order_id"
    t.integer "channel", default: 0, null: false
    t.integer "priority", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "opened_at", null: false
    t.datetime "resolved_at"
    t.integer "resolution_minutes"
    t.integer "satisfaction"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_support_tickets_on_account_id"
    t.index ["customer_id"], name: "index_support_tickets_on_customer_id"
    t.index ["order_id"], name: "index_support_tickets_on_order_id"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "email", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
  end

  add_foreign_key "coupons", "accounts"
  add_foreign_key "customers", "accounts"
  add_foreign_key "invoices", "accounts"
  add_foreign_key "invoices", "customers"
  add_foreign_key "invoices", "subscriptions"
  add_foreign_key "line_items", "orders"
  add_foreign_key "line_items", "products"
  add_foreign_key "orders", "accounts"
  add_foreign_key "orders", "coupons"
  add_foreign_key "orders", "customers"
  add_foreign_key "products", "accounts"
  add_foreign_key "refunds", "orders"
  add_foreign_key "reviews", "customers"
  add_foreign_key "reviews", "products"
  add_foreign_key "security_disputes", "security_payments"
  add_foreign_key "security_notes", "accounts"
  add_foreign_key "security_payments", "orders"
  add_foreign_key "shipments", "orders"
  add_foreign_key "subscriptions", "accounts"
  add_foreign_key "subscriptions", "customers"
  add_foreign_key "support_tickets", "accounts"
  add_foreign_key "support_tickets", "customers"
  add_foreign_key "support_tickets", "orders"
  add_foreign_key "users", "accounts"
end
