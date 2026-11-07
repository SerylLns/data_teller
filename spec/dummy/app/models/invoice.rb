class Invoice < ApplicationRecord
  belongs_to :account
  belongs_to :customer
  belongs_to :subscription, optional: true

  enum :status, { draft: 0, open: 1, paid: 2, void: 3 }, prefix: true
end
