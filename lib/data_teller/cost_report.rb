module DataTeller
  # rake data_teller:costs (ADR 0013 D4): the planner's estimate next to the real duration, for each query of the isolation kit, as
  # each tenant. What an integrator needs to choose max_query_cost on their own data: a cost alone has no unit they can relate to.
  # It runs every query for real, read-only and rolled back, each under query_timeout. The report holds dataset names, query
  # shapes, tenant keys, costs and durations, never a value.
  class CostReport
    # cost: the planner's estimate, the sum over the query's statements as max_query_cost compares it. ms: what the statements took,
    # nil when query_timeout stopped them. refusal: why the query was not measured, nil when it was.
    Line = Data.define(:dataset, :shape, :tenant, :cost, :ms, :refusal)

    def initialize(tenants:, registry: DataTeller.registry, config: DataTeller.config, now: Time.current)
      @kit = IsolationCheck.new(registry: registry, config: config, tenants: tenants, now: now)
      @tenants = tenants
    end

    def call
      @tenants.flat_map { |tenant| @kit.probes.map { |probe| measured(probe, tenant) } }
    end

    private

    def measured(probe, tenant)
      query = probe.query
      if probe.other_value
        # The tenant's own value: a filter that matches, as a real question's does. The kit reads another tenant's to find leaks.
        value = @kit.value_seen_by(probe.other_value, tenant)
        return line(probe, tenant, refusal: :no_value) if value.nil?

        query = query.merge("filters" => [ { "dimension" => probe.other_value.name.to_s, "op" => "eq", "value" => value } ])
      end

      # Estimated apart, before it runs: a query the time budget stops still has its cost, and it is the one that matters most.
      cost = @kit.as_the_app(query, tenant) { |plan| QueryCost.estimate(plan.model, plan.statements) }.sum
      line(probe, tenant, cost: cost, ms: duration(query, tenant))
    rescue Compiler::Refused => e
      # As the kit says it: which rule refused tells the integrator more than unsupported_query.
      line(probe, tenant, refusal: e.codes.any? ? e.codes.join("+") : e.reason)
    rescue ActiveRecord::StatementInvalid, ReadOnlyExecution::OutOfTime => e
      # The class only: a database message can hold values.
      line(probe, tenant, refusal: e.class.name)
    end

    def duration(query, tenant)
      @kit.as_the_app(query, tenant) { |plan| QueryCost.measure(plan.model, plan.statements) }.sum
    rescue ActiveRecord::QueryCanceled, ReadOnlyExecution::OutOfTime
      nil
    end

    def line(probe, tenant, cost: nil, ms: nil, refusal: nil)
      shape = probe.other_value ? "#{probe.other_value.name} = one of its values" : probe.shape
      Line.new(dataset: probe.dataset, shape: shape, tenant: tenant.public_send(tenant.class.primary_key), cost: cost, ms: ms, refusal: refusal)
    end
  end
end
