require "digest"

module DataTeller
  # The first of two calls (ADR 0007): picks the datasets a question may be about, from a short index of the role's catalog, so that
  # the query call gets a schema a provider accepts whatever the size of the catalog. It reads only the role's catalog, so it cannot
  # name a forbidden dataset, and it never refuses: only the query call answers out_of_scope (D4).
  class Router
    MAX_DATASETS = 3

    TEMPLATE = <<~TEXT.freeze
      You pick which datasets of a business application may answer one question. You never see data. The question may be in English or in French.

      Return 1 to #{MAX_DATASETS} dataset names, most likely first. If the question could be about several datasets, return them all.
      If none fits, return your best guess anyway: another step decides whether the question can be answered.

      Datasets:
      %<index>s
    TEXT

    Route = Data.define(:datasets, :input_tokens, :cached_input_tokens, :output_tokens, :latency_ms)

    # Names the prompt in saved runs, like Prompt.fingerprint.
    def self.fingerprint = Digest::SHA256.hexdigest(TEMPLATE)[0, 12]

    def initialize(llm, catalog)
      @llm = llm
      # A dataset with no visible metric has no branch in the query schema (SchemaGenerator), so it cannot be routed to.
      @entries = catalog.datasets.select { |entry| entry.metrics.any? }
    end

    def call(question)
      # Nothing to narrow, so no call: this also covers a role that sees nothing, whose enum would be empty.
      return Route.new(datasets: names, input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, latency_ms: 0) if names.size <= MAX_DATASETS

      response = @llm.complete(system: system, user: question, schema: schema)
      Route.new(datasets: chosen(response.output), input_tokens: response.input_tokens.to_i, cached_input_tokens: response.cached_input_tokens.to_i,
                output_tokens: response.output_tokens.to_i, latency_ms: response.latency_ms.to_i)
    end

    def system
      format(TEMPLATE, index: index)
    end

    # Names of datasets and metrics only: what the role may see, nothing from the database (ADR 0007 D3).
    def index
      @entries.sort_by { |entry| entry.name.to_s }.map do |entry|
        synonyms = entry.dataset.synonyms
        "#{entry.name}#{" (#{synonyms.join(', ')})" if synonyms.any?}: metrics #{entry.metrics.map(&:name).join(', ')}"
      end.join("\n")
    end

    def schema
      {
        "type" => "object",
        "additionalProperties" => false,
        "required" => [ "datasets" ],
        "properties" => {
          "datasets" => { "type" => "array", "minItems" => 1, "maxItems" => MAX_DATASETS, "uniqueItems" => true, "items" => { "enum" => names } }
        }
      }
    end

    private

    def names = @entries.map { |entry| entry.name.to_s }

    # The schema is not a security boundary, and an integrator's adapter may not enforce it: what comes back is judged here too.
    def chosen(output)
      answered = output.is_a?(Hash) ? Array(output["datasets"]) : []
      kept = answered.uniq.select { |name| names.include?(name) }.first(MAX_DATASETS)
      raise LLM::InvalidResponse, "the router named no dataset of the catalog" if kept.empty?

      kept
    end
  end
end
