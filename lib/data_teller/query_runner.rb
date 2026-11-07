module DataTeller
  # From a query and a user to an outcome: who is asking, what they can see, then validate, compile, run.
  # Everything is decided per request from the user, nothing is kept between two calls.
  class QueryRunner
    Outcome = Data.define(:status, :query, :result, :refusal, :trace)

    # For the developer only, with `trace: true` (ADR 0005 D5): where the query stopped (nil when it went through), the
    # validator's codes and pointers, the names refused as unknown that other roles see, and the SQL that ran, in order.
    # It names tables, columns and names the user may not see, and holds the SQL with its values: never show it to an end user.
    Trace = Data.define(:stage, :problems, :hidden, :sql)

    STAGES = %i[access validation compilation execution].freeze

    def self.call(query, user:, now: Time.current, trace: false)
      new(query, user, now, trace).call
    end

    def initialize(query, user, now, trace = false)
      @query = query
      @user = user
      @now = now
      @trace = trace
      @stage = :access
      @problems = []
      @sql = []
    end

    def call
      return refused(:engine_disabled) unless DataTeller.enabled?

      tenant = DataTeller.config.tenant_for(@user)
      return refused(:no_tenant) unless tenant

      @stage = :validation
      catalog = Catalog.for_user(@user)
      validation = QueryValidator.new(catalog).call(@query)
      @problems = validation.problems
      @hidden = HiddenNames.new(@query, catalog).call(@problems) if @trace && !validation.ok?
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
      # A column missing despite `rake data_teller:check` (ADR 0004 D6), a scope that tried to write, or a column the database
      # role cannot read. Only the classes: the message holds SQL and values. The cause tells a permission from the rest.
      Rails.logger&.error("[DataTeller] query failed in the database: #{e.class} (#{e.cause.class})")
      refused(:unsupported_query)
    end

    private

    def answer(catalog, tenant)
      # The tenant's time zone is an input of the compilation: a broken one stops it there.
      @stage = :compilation
      time_zone = needs_time_zone? ? DataTeller.config.time_zone_for(tenant) : Time.zone
      return refused(:unsupported_query) unless time_zone

      model = catalog.dataset(@query["dataset"]).model_name.constantize
      result = ReadOnlyExecution.run(model, timeout: DataTeller.config.statement_timeout, role: DataTeller.config.database_role,
                                            tenant_id: (tenant.id if DataTeller.config.row_security)) do
        plan = Compiler.new(catalog: catalog, tenant: tenant, time_zone: time_zone, now: @now).call(@query)
        @stage = :execution
        plan.execute(recorder: (->(sql) { @sql << sql } if @trace))
      end

      @stage = nil
      outcome(:answered, result: result)
    end

    # A count has no "today": a tenant's broken time zone must not refuse it.
    def needs_time_zone?
      @query["period"] || Array(@query["group_by"]).any? { |item| item["granularity"] }
    end

    def passed_through
      @stage = nil
      outcome(@query["intent"].to_sym)
    end

    # Codes and JSON pointers only: the problems hold none of the names the LLM wrote (see QueryValidator).
    def log_and_refuse(validation)
      Rails.logger&.info("[DataTeller] query refused: #{validation.problems.map { |problem| "#{problem[:pointer]}=#{problem[:code]}" }.join(', ')}")
      refused(validation.refusal.reason)
    end

    def refused(reason)
      outcome(:refused, refusal: QueryValidator::Refusal.new(reason: reason))
    end

    def outcome(status, result: nil, refusal: nil)
      trace = Trace.new(stage: @stage, problems: @problems, hidden: @hidden || [], sql: @sql.freeze) if @trace
      Outcome.new(status: status, query: @query, result: result, refusal: refusal, trace: trace)
    end
  end
end
