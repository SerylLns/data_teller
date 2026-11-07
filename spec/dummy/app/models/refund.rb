class Refund < ApplicationRecord
  belongs_to :order

  enum :reason, { damaged: 0, late: 1, wrong_item: 2, changed_mind: 3 }, prefix: true
end
