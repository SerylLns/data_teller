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

    # after: the cursor of a list's next page (ADR 0016 D4).
    def self.call(query, user:, now: Time.current, trace: false, after: nil)
      new(query, user, now, trace, after).call
    end

    def initialize(query, user, now, trace = false, after = nil)
      @query = query
      @user = user
      @now = now
      @trace = trace
      @after = after
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
    rescue ActiveRecord::QueryCanceled, ReadOnlyExecution::OutOfTime => e
      Rails.logger&.error("[DataTeller] query stopped by the time budget: #{e.class}")
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
      result = ReadOnlyExecution.run(model, timeout: DataTeller.config.query_timeout, role: DataTeller.config.database_role,
                                            tenant_id: (tenant.id if DataTeller.config.row_security)) do
        plan = Compiler.new(catalog: catalog, tenant: tenant, time_zone: time_zone, now: @now).call(@query, after: @after)
        @stage = :execution
        check_cost(model, plan)
        plan.execute(recorder: recorder)
      end

      @stage = nil
      outcome(:answered, result: result)
    end

    # Before anything runs, so a question too heavy has read no row (ADR 0013 D3).
    def check_cost(model, plan)
      maximum = DataTeller.config.max_query_cost
      return unless maximum

      cost = QueryCost.estimate(model, plan.statements, recorder: recorder)
      return if cost <= maximum

      # The numbers are the planner's, no value of a row: they are what the integrator needs to tune the setting.
      Rails.logger&.info("[DataTeller] estimated cost #{cost.round} is over max_query_cost #{maximum}")
      raise Compiler::Refused.new(:too_complex)
    end

    def recorder
      ->(sql) { @sql << sql } if @trace
    end

    # A count has no "today": a tenant's broken time zone must not refuse it. A list shows its dates in that zone.
    def needs_time_zone?
      @query["period"] || @query["list"] || Array(@query["group_by"]).any? { |item| item["granularity"] }
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
