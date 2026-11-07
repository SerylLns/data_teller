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

ActiveRecord::Schema[8.1].define(version: 2026_01_01_000003) do
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

  create_table "customers", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "email", null: false
    t.string "phone"
    t.string "city"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_customers_on_account_id"
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
    t.index ["account_id", "status", "ship_on"], name: "index_orders_on_account_id_and_status_and_ship_on"
    t.index ["account_id"], name: "index_orders_on_account_id"
    t.index ["customer_id"], name: "index_orders_on_customer_id"
  end

  create_table "products", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "name", null: false
    t.string "category", null: false
    t.integer "price_cents", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_products_on_account_id"
  end

  create_table "shipments", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.string "carrier", null: false
    t.datetime "shipped_at"
    t.date "delivered_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_shipments_on_order_id"
  end

  create_table "users", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "email", null: false
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
  end

  add_foreign_key "customers", "accounts"
  add_foreign_key "line_items", "orders"
  add_foreign_key "line_items", "products"
  add_foreign_key "orders", "accounts"
  add_foreign_key "orders", "customers"
  add_foreign_key "products", "accounts"
  add_foreign_key "shipments", "orders"
  add_foreign_key "users", "accounts"
end
