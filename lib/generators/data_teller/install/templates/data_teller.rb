# DataTeller global configuration. One file per exposed model goes in config/data_teller/.
DataTeller.configure do |c|
  # REQUIRED: the tenant model, and how to find the tenant of the current user. The compiler scopes every query to it.
  # The app does not boot until this is set: there is no safe default to guess.
  # c.tenant do
  #   model Account
  #   resolve { |user| user.account }
  # end

  # Returns the roles of the current user. No resolver, nil or an error all mean no access.
  # c.roles { |user| user.roles }

  # Who is asking, for the palette and its endpoint. No block, nil or an error all mean no access.
  # c.current_user { |request| request.env["warden"]&.user }

  # The provider. The key comes from the environment. The question and the role's catalog are sent to it, never rows.
  # c.llm = DataTeller::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model: "gpt-6-luna")

  # Models that can be queried, each one declared in config/data_teller/<dataset>.rb with its roles and its tenant_path.
  # A model that is not listed here cannot be queried.
  # c.expose Order

  # Recommended: run each query as a Postgres role that can read the declared columns only, so that a bug in DataTeller
  # cannot read anything else. `rake data_teller:grants` prints the SQL creating it; `rake data_teller:check` verifies it.
  # c.database_role = "data_teller_reader"

  # Recommended with database_role: Postgres row-level security keeps that role to the current tenant's rows, on top of the
  # filter DataTeller adds itself. `rake data_teller:grants` prints the policies too; tables with policies of their own are refused.
  # c.row_security = true

  # What to do when this configuration is invalid. In both cases the engine stays off.
  #   :raise   (default) the app refuses to boot
  #   :disable the app boots without the engine, with an error in the log
  # c.on_invalid_config = :raise
end
