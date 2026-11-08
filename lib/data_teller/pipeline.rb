module DataTeller
  # From a question to a query, not yet checked: route, then write the query against the narrowed catalog (ADR 0007 D1). What comes
  # back goes through the validator and the compiler like any other output, with the role's whole catalog as the limit.
  class Pipeline
    Result = Data.define(:output, :route, :input_tokens, :cached_input_tokens, :output_tokens, :latency_ms, :model)

    def initialize(llm:, router_llm: llm)
      @llm = llm
      @router_llm = router_llm
    end

    def call(question, catalog:, today:, time_zone:)
      route = Router.new(@router_llm, catalog).call(question)
      narrowed = catalog.only(route.datasets)
      response = @llm.complete(system: Prompt.new(narrowed, today: today, time_zone: time_zone).system, user: question,
                               schema: SchemaGenerator.new(narrowed).call)

      Result.new(output: response.output, route: route.datasets,
                 input_tokens: route.input_tokens + response.input_tokens.to_i,
                 cached_input_tokens: route.cached_input_tokens + response.cached_input_tokens.to_i,
                 output_tokens: route.output_tokens + response.output_tokens.to_i,
                 latency_ms: route.latency_ms + response.latency_ms.to_i,
                 model: response.model)
    end
  end
end
