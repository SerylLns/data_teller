class Customer < ApplicationRecord
  belongs_to :account
  has_many :orders, dependent: :destroy
end
