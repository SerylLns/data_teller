class Coupon < ApplicationRecord
  belongs_to :account
  has_many :orders, dependent: :nullify

  enum :kind, { percent: 0, fixed: 1, free_shipping: 2 }, prefix: true
end
