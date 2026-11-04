class Order < ApplicationRecord
  belongs_to :account
  belongs_to :customer
  has_many :line_items, dependent: :destroy
  has_many :shipments, dependent: :destroy

  enum :status, { pending: 0, paid: 1, shipped: 2, delivered: 3, cancelled: 4 }

  # Business scope the DSL will reuse by name; the date is a parameter on purpose,
  # a lambda calling Date.tomorrow would ignore the tenant time zone.
  scope :to_ship_on, ->(date) { paid.where(ship_on: date) }
end
