class Customer < ApplicationRecord
  belongs_to :account
  has_many :orders, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :support_tickets, dependent: :destroy
  has_many :reviews, dependent: :destroy

  # Prefixed, as every enum added for the evaluation domain: values such as `open` or `store` would collide with existing methods.
  enum :acquisition_channel, { organic: 0, ads: 1, referral: 2, marketplace: 3 }, prefix: true
  enum :tier, { bronze: 0, silver: 1, gold: 2 }, prefix: true
end
