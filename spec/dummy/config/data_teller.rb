DataTeller.configure do |c|
  c.tenant do
    model Account
    resolve { |user| user.account }
    time_zone { |account| account.time_zone }
  end
  c.roles { |user| user.roles }
  c.expose Order, Customer, Product, LineItem, Shipment, Refund, Coupon, Subscription, Invoice, SupportTicket, Review

  # Real eval runs only (ADR 0008 D2): the key comes from the shell, never from a file in the repo, and the CI has none.
  if ENV["OPENAI_API_KEY"].present?
    c.llm = DataTeller::Providers::OpenAI.new(api_key: ENV["OPENAI_API_KEY"], model: ENV.fetch("OPENAI_MODEL", "gpt-6-luna"))
  end
end
