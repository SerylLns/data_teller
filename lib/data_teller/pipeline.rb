module DataTeller
  # From a question to a query, not yet checked: the role's whole catalog when it is small, otherwise a router first (ADR 0007 D6).
  # What comes back goes through the validator and the compiler like any other output, with the role's whole catalog as the limit.
  class Pipeline
    Result = Data.define(:output, :route, :input_tokens, :cached_input_tokens, :output_tokens, :latency_ms, :model)

    NO_ROUTE = Router::Route.new(datasets: nil, input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, latency_ms: 0)

    def initialize(llm:, router_llm: llm, route_above: DataTeller.config.route_above_datasets)
      @llm = llm
      @router_llm = router_llm
      @route_above = route_above
    end

    def call(question, catalog:, today:, time_zone:)
      route = route_for(question, catalog)
      sent = route.datasets ? catalog.only(route.datasets) : catalog
      response = @llm.complete(system: Prompt.new(sent, today: today, time_zone: time_zone).system, user: question,
                               schema: SchemaGenerator.new(sent).call)

      Result.new(output: response.output, route: route.datasets,
                 input_tokens: route.input_tokens + response.input_tokens.to_i,
                 cached_input_tokens: route.cached_input_tokens + response.cached_input_tokens.to_i,
                 output_tokens: route.output_tokens + response.output_tokens.to_i,
                 latency_ms: route.latency_ms + response.latency_ms.to_i,
                 model: response.model)
    end

    private

    # Measured on eleven datasets: no router scores a little better, answers faster and costs the same (ADR 0007). It is there for what
    # a provider cannot take whole.
    def route_for(question, catalog)
      return NO_ROUTE if catalog.datasets.count { |entry| entry.metrics.any? } <= @route_above

      Router.new(@router_llm, catalog).call(question)
    end
  end
end
