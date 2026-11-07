class Account < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :products, dependent: :destroy
  has_many :orders, dependent: :destroy
end
