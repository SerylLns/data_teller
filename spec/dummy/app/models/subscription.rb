class Subscription < ApplicationRecord
  belongs_to :account
  belongs_to :customer
  has_many :invoices, dependent: :nullify

  enum :plan, { starter: 0, pro: 1, business: 2 }, prefix: true
  enum :status, { trialing: 0, active: 1, past_due: 2, cancelled: 3 }, prefix: true
end
