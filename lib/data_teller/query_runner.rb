module DataTeller
  # From a query and a user to an outcome: who is asking, what they can see, then validate, compile, run.
  # Everything is decided per request from the user, nothing is kept between two calls.
  class QueryRunner
    Outcome = Data.define(:status, :query, :result, :refusal)

    def self.call(query, user:, now: Time.current)
      new(query, user, now).call
    end

    def initialize(query, user, now)
      @query = query
      @user = user
      @now = now
    end

    def call
      return refused(:engine_disabled) unless DataTeller.enabled?

      tenant = DataTeller.config.tenant_for(@user)
      return refused(:no_tenant) unless tenant

      catalog = Catalog.for_user(@user)
      validation = QueryValidator.new(catalog).call(@query)
      return log_and_refuse(validation) unless validation.ok?
      return passed_through unless @query["intent"] == "answer"

      answer(catalog, tenant)
    rescue Compiler::Refused => e
      Rails.logger&.info("[DataTeller] query refused by the compiler: #{e.reason}")
      refused(e.reason)
    rescue ActiveRecord::QueryCanceled => e
      Rails.logger&.error("[DataTeller] query cancelled by the statement timeout: #{e.class}")
      refused(:query_timeout)
    rescue ActiveRecord::StatementInvalid => e
      # A column missing despite `rake data_teller:check` (ADR 0004 D6), or a scope that tried to write.
      # Only the class: the message holds SQL and values.
      Rails.logger&.error("[DataTeller] query failed in the database: #{e.class}")
      refused(:unsupported_query)
    end

    private

    def answer(catalog, tenant)
      time_zone = needs_time_zone? ? DataTeller.config.time_zone_for(tenant) : Time.zone
      return refused(:unsupported_query) unless time_zone

      model = catalog.dataset(@query["dataset"]).model_name.constantize
      result = ReadOnlyExecution.run(model, timeout: DataTeller.config.statement_timeout) do
        Compiler.new(catalog: catalog, tenant: tenant, time_zone: time_zone, now: @now).call(@query).execute
      end

      Outcome.new(status: :answered, query: @query, result: result, refusal: nil)
    end

    # A count has no "today": a tenant's broken time zone must not refuse it.
    def needs_time_zone?
      @query["period"] || Array(@query["group_by"]).any? { |item| item["granularity"] }
    end

    def passed_through
      Outcome.new(status: @query["intent"].to_sym, query: @query, result: nil, refusal: nil)
    end

    # Codes and JSON pointers only: the problems hold none of the names the LLM wrote (see QueryValidator).
    def log_and_refuse(validation)
      Rails.logger&.info("[DataTeller] query refused: #{validation.problems.map { |problem| "#{problem[:pointer]}=#{problem[:code]}" }.join(', ')}")
      refused(validation.refusal.reason)
    end

    def refused(reason)
      Outcome.new(status: :refused, query: @query, result: nil, refusal: QueryValidator::Refusal.new(reason: reason))
    end
  end
end
