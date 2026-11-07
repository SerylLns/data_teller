class Order < ApplicationRecord
  belongs_to :account
  belongs_to :customer
  belongs_to :coupon, optional: true
  has_many :line_items, dependent: :destroy
  has_many :shipments, dependent: :destroy
  has_many :refunds, dependent: :destroy

  enum :status, { pending: 0, paid: 1, shipped: 2, delivered: 3, cancelled: 4 }
  enum :channel, { web: 0, mobile: 1, store: 2 }, prefix: true

  # Business scope the DSL will reuse by name; the date is a parameter on purpose,
  # a lambda calling Date.tomorrow would ignore the tenant time zone.
  scope :to_ship_on, ->(date) { paid.where(ship_on: date) }
  # Used as a segment (`scope:`): a condition a declarative `where:` hash cannot write.
  scope :with_coupon, -> { where.not(coupon_id: nil) }
end
