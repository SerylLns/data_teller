class Product < ApplicationRecord
  belongs_to :account
  has_many :line_items, dependent: :restrict_with_exception
  has_many :reviews, dependent: :destroy
end
