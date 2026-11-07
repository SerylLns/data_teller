class SupportTicket < ApplicationRecord
  belongs_to :account
  belongs_to :customer
  belongs_to :order, optional: true

  enum :channel, { email: 0, chat: 1, phone: 2 }, prefix: true
  enum :priority, { low: 0, normal: 1, high: 2, urgent: 3 }, prefix: true
  enum :status, { open: 0, pending: 1, solved: 2, closed: 3 }, prefix: true
end
