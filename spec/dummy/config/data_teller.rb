DataTeller.configure do |c|
  c.tenant do
    model Account
    resolve { |user| user.account }
    time_zone { |account| account.time_zone }
  end
  c.roles { |user| user.roles }
  # FAKE authentication, for this dummy app only: see DummySessionsController. A real app reads its own session here.
  c.current_user { |request| User.find_by(id: request.session[:dummy_user_id]) }
  # DUMMY_LOCALE=fr bin/rails server, to try the palette in French: the dummy's users have no language of their own.
  c.locale { |_user| ENV["DUMMY_LOCALE"] }
  c.expose Order, Customer, Product, LineItem, Shipment, Refund, Coupon, Subscription, Invoice, SupportTicket, Review

  # Real eval runs only (ADR 0008 D2): the key comes from the shell, never from a file in the repo, and the CI has none.
  if ENV["OPENAI_API_KEY"].present?
    c.llm = DataTeller::Providers::OpenAI.new(api_key: ENV["OPENAI_API_KEY"], model: ENV.fetch("OPENAI_MODEL", "gpt-6-luna"))
  end
end
