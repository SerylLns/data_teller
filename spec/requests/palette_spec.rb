require "rails_helper"

RSpec.describe "the palette", type: :request do
  let(:acme) { Account.create!(name: "PaletteSpec Acme", time_zone: "UTC") }
  let(:globex) { Account.create!(name: "PaletteSpec Globex", time_zone: "UTC") }
  let(:adapter_class) do
    Struct.new(:outputs, :calls) do
      def provider_schema(schema) = schema

      def complete(system:, user:, schema:)
        calls << user
        output = outputs.shift
        raise output if output.is_a?(Exception)

        DataTeller::LLM::Response.new(output: output, input_tokens: 1, output_tokens: 1, latency_ms: 1, model: "fake")
      end
    end
  end
  let(:count_orders) { { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "count" } }

  def with_llm(*outputs)
    adapter = adapter_class.new(outputs, [])
    config = DataTeller.config.dup.tap { |copy| copy.llm = adapter }
    allow(DataTeller).to receive(:config).and_return(config)
    adapter
  end

  def sign_in(account, role)
    post "/dummy_sign_in", params: { user_id: User.create!(account: account, email: "#{role}@#{account.id}.test", role: role).id }
  end

  def ask(question = "how many orders?") = post("/data_teller/ask", params: { data_teller_question: question })

  def order(account, name: "Someone")
    customer = Customer.create!(account: account, name: name, email: "#{name.hash}@example.test", city: "Paris")
    Order.create!(account: account, customer: customer, status: :paid, total_cents: 100, ordered_at: Time.current)
  end

  describe "POST /ask" do
    it "needs a user, and pays nothing without one" do
      adapter = with_llm(count_orders)

      ask

      expect(response).to have_http_status(:unauthorized)
      expect(adapter.calls).to be_empty
    end

    it "treats a failing current_user block as nobody" do
      adapter = with_llm(count_orders)
      allow(DataTeller.config).to receive(:current_user_for).and_return(nil)
      sign_in(acme, "admin")

      ask

      expect(response).to have_http_status(:unauthorized)
      expect(adapter.calls).to be_empty
    end

    it "answers with the rows of the user's own tenant" do
      with_llm(count_orders)
      2.times { order(acme) }
      order(globex)
      sign_in(acme, "admin")

      ask

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("orders · count", "<td>2</td>")
    end

    it "takes the role from the signed-in user: a member cannot read revenue, whatever the model answers" do
      with_llm(count_orders.merge("metric" => "revenue"))
      sign_in(acme, "member")

      ask("how much revenue?")

      expect(response.body).to include("isn&#39;t something I can answer")
      expect(response.body).not_to include("revenue")
    end

    it "gives a forbidden name and an unknown one the same answer" do
      with_llm(count_orders.merge("metric" => "revenue"), count_orders.merge("metric" => "nothing_like_this"))
      sign_in(acme, "member")

      ask
      forbidden = response.body
      ask

      expect(response.body).to eq(forbidden)
    end

    it "escapes what the database holds" do
      with_llm(count_orders.merge("metric" => "count", "group_by" => [ { "dimension" => "customer.name" } ]))
      order(acme, name: "<script>alert(1)</script>")
      sign_in(acme, "admin")

      ask

      expect(response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(response.body).not_to include("<script>")
    end

    it "shows the options of a clarification, the role's names only" do
      with_llm({ "version" => 1, "intent" => "clarify", "clarify" => { "reason" => "ambiguous_metric", "options" => %w[revenue net_revenue] } })
      sign_in(acme, "admin")

      ask

      expect(response.body).to include("Which one did you mean?", "<li>revenue</li>", "<li>net_revenue</li>")
    end

    it "shows a translated refusal for what is out of scope" do
      with_llm({ "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "not_a_data_question" } })
      sign_in(acme, "admin")

      ask("will it rain?")

      expect(response.body).to include("I can only answer questions about your data.")
    end

    it "says nothing of a provider's failure, and never shows the query or the SQL" do
      with_llm(DataTeller::LLM::ProviderError.new("401: sk-secret"), count_orders)
      order(acme)
      sign_in(acme, "admin")

      ask
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("not available right now")
      expect(response.body).not_to include("sk-secret", "401")

      ask
      expect(response.body).not_to include("SELECT", "account_id", "\"intent\"")
    end

    [ { data_teller_question: "x" * 501 }, { data_teller_question: "" }, {}, { data_teller_question: { nested: "x" } }, { data_teller_question: [ "x" ] } ].each do |params|
      it "refuses #{params.inspect.truncate(30)} without paying" do
        adapter = with_llm(count_orders)
        sign_in(acme, "admin")

        post "/data_teller/ask", params: params

        expect(response.body).to include("500 characters")
        expect(adapter.calls).to be_empty
      end
    end

    # Found on the first real run: Rails logs every parameter, and the question is the end user's.
    it "keeps the question out of the logs" do
      with_llm(count_orders)
      sign_in(acme, "admin")
      logged = {}
      subscriber = ActiveSupport::Notifications.subscribe("process_action.action_controller") { |*, payload| logged = payload[:params] if payload[:action] == "create" && payload[:controller] == "DataTeller::QuestionsController" }

      ask("how much does jane.doe@example.com owe?")

      expect(logged["data_teller_question"]).to eq("[FILTERED]")
      expect(logged.to_s).not_to include("jane.doe")
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "translates into the app's locale" do
      with_llm({ "version" => 1, "intent" => "out_of_scope", "out_of_scope" => { "reason" => "not_a_data_question" } })
      sign_in(acme, "admin")

      I18n.with_locale(:fr) { ask }

      expect(response.body).to include("Je ne réponds qu&#39;aux questions sur vos données.")
    end
  end

  describe "CSRF", :aggregate_failures do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    def csrf_token_of_sign_in = Nokogiri::HTML(response.body).at("input[name=authenticity_token]")["value"]

    def sign_in_with_token(user)
      get "/"
      post "/dummy_sign_in", params: { user_id: user.id, authenticity_token: csrf_token_of_sign_in }
      follow_redirect!
    end

    let(:user) { User.create!(account: acme, email: "csrf@example.test", role: "admin") }

    it "refuses a question without the token, before anything is paid" do
      adapter = with_llm(count_orders)
      sign_in_with_token(user)

      ask

      expect(response).to have_http_status(422)
      expect(adapter.calls).to be_empty
    end

    it "accepts the token the helper put on the element" do
      adapter = with_llm(count_orders)
      sign_in_with_token(user)
      token = Nokogiri::HTML(response.body).at("data-teller-palette")["data-csrf-token"]

      post "/data_teller/ask", params: { data_teller_question: "?" }, headers: { "X-CSRF-Token" => token }

      expect(response).to have_http_status(:ok)
      expect(adapter.calls).to eq([ "?" ])
    end

    it "serves its script to a plain <script src>, which is not an XHR" do
      get "/data_teller/palette.js"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/javascript")
      expect(response.body).to include("customElements.define")
      expect(response.headers["Cache-Control"]).to include("public")
    end
  end

  describe "when the engine is off (ADR 0004 D6)" do
    before { allow(DataTeller).to receive(:enabled?).and_return(false) }

    it "answers 503 on every route" do
      ask
      expect(response).to have_http_status(:service_unavailable)

      get "/data_teller/palette.js"
      expect(response).to have_http_status(:service_unavailable)

      get "/data_teller/palette.css"
      expect(response).to have_http_status(:service_unavailable)
    end

    it "does not render the palette" do
      sign_in(acme, "admin")
      get "/"

      expect(response.body).not_to include("data-teller-palette", "palette.js")
    end
  end

  describe "the helper" do
    it "renders nothing for nobody" do
      get "/"

      expect(response.body).not_to include("<data-teller-palette", "palette.js")
    end

    it "renders nothing for a role that sees nothing" do
      sign_in(acme, "no_such_role")
      get "/"

      expect(response.body).not_to include("<data-teller-palette", "palette.js")
    end

    it "renders the element and its files, with no inline script or style" do
      sign_in(acme, "admin")
      get "/"

      page = Nokogiri::HTML(response.body)
      element = page.at("data-teller-palette")
      expect(element.to_h).to include("data-mode" => "modal", "data-theme" => "system", "data-shortcut" => "mod+k", "data-endpoint" => "/data_teller/ask")
      expect(element["data-csrf-token"]).to be_present
      expect(page.at("script[src^='/data_teller/palette.js']")).to be_present
      expect(page.at("link[href^='/data_teller/palette.css']")).to be_present
      expect(page.css("script:not([src])")).to be_empty
      expect(page.css("style")).to be_empty
      expect(page.css("[style]")).to be_empty
    end

    it "can be put inline in one page" do
      sign_in(acme, "admin")
      get "/"
      helper = ApplicationController.new.tap { |controller| controller.request = request }.view_context

      expect(helper.data_teller_palette(mode: :inline)).to include('data-mode="inline"')
    end
  end

  # Every reason a query can be refused for has a sentence, in both languages: a missing key would show a raw translation error.
  it "has a sentence for every reason, in both languages" do
    reasons = %w[engine_disabled invalid_question llm_unavailable no_tenant query_timeout too_many_groups unknown_dataset unknown_metric unsupported_query not_a_data_question]
    %i[en fr].each do |locale|
      reasons.each { |reason| expect(I18n.exists?("data_teller.refusal.#{reason}", locale)).to be(true), "#{locale}: #{reason}" }
    end
  end
end
