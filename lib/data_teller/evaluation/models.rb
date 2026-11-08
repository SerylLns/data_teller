require "json"

module DataTeller
  module Evaluation
    # What `rake data_teller:eval` asks a model, and what it gets back (T11). A real LLM adapter (T12) takes the same request: the
    # question's text, never its expected query.
    Request = Data.define(:id, :language, :text, :role, :today)
    # cached_input_tokens and model as the provider reported them (ADR 0009 D1); failure: the class of the error that left no
    # output, never its message; route: the datasets a router chose, most likely first.
    Response = Data.define(:output, :input_tokens, :output_tokens, :latency_ms, :cached_input_tokens, :model, :failure, :route) do
      def initialize(output:, input_tokens:, output_tokens:, latency_ms:, cached_input_tokens: 0, model: nil, failure: nil, route: nil)
        super
      end
    end

    module Models
      # Answers what the file expects. Calibrates the harness: anything but 100% is a bug of the eval, not of a model.
      class Perfect
        def initialize(set)
          @expected = set.questions.to_h { |question| [ question.id, question.expected ] }
        end

        def name = "perfect"
        def fingerprint = nil

        def call(request)
          Response.new(output: @expected.fetch(request.id), input_tokens: 0, output_tokens: 0, latency_ms: 0)
        end
      end

      # Answers what a recorded run answered: a run scored again after a change to the scorer, or a demo that must not call a
      # provider. Held-out runs record no output, so they cannot be replayed.
      class Replay
        def initialize(path)
          record = JSON.parse(File.read(path))
          @name = "replay of #{record.fetch('model')}"
          @fingerprint = record["fingerprint"]
          @answers = record.fetch("answers").to_h { |answer| [ [ answer.fetch("id"), answer.fetch("language") ], answer ] }
          raise ArgumentError, "#{path} records no output (a held-out run), it cannot be replayed" if @answers.values.none? { |answer| answer.key?("output") }
        end

        attr_reader :name, :fingerprint

        def call(request)
          answer = @answers[[ request.id, request.language ]]
          return Response.new(output: nil, input_tokens: 0, output_tokens: 0, latency_ms: 0) unless answer

          Response.new(output: answer["output"], input_tokens: answer["input_tokens"].to_i, output_tokens: answer["output_tokens"].to_i,
                       latency_ms: answer["latency_ms"].to_i, cached_input_tokens: answer["cached_input_tokens"].to_i,
                       model: answer["answered_by"], failure: answer["failure"], route: answer["route"])
        end
      end

      # The model's own failures to answer: they score as invalid_output, like a refusal the user would get. Anything else (a
      # refused key, a schema OpenAI rejects, the network) stops the run: a score with them in it would measure the transport.
      ANSWER_FAILURES = [ LLM::Refused, LLM::IncompleteResponse, LLM::InvalidResponse ].freeze

      # The whole role's catalog in the prompt, one call per question (ADR 0007 D1, ADR 0009): the reference number, never shipped.
      class Naive
        def initialize(llm:, time_zone:)
          @llm = llm
          @time_zone = time_zone
          @schemas = {}
        end

        def name = "naive #{@llm.respond_to?(:model) ? @llm.model : @llm.class.name}"
        def fingerprint = "prompt #{Prompt.fingerprint}"

        def call(request)
          catalog = Catalog.for(request.role)
          started = monotonic_ms
          response = @llm.complete(system: Prompt.new(catalog, today: request.today, time_zone: @time_zone).system, user: request.text,
                                   schema: @schemas[request.role] ||= SchemaGenerator.new(catalog).call)
          Response.new(output: response.output, input_tokens: response.input_tokens.to_i, output_tokens: response.output_tokens.to_i,
                       latency_ms: response.latency_ms.to_i, cached_input_tokens: response.cached_input_tokens.to_i, model: response.model)
        rescue *ANSWER_FAILURES => e
          Response.new(output: nil, input_tokens: 0, output_tokens: 0, latency_ms: monotonic_ms - started, failure: e.class.name.demodulize)
        end

        private

        def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end

      # The path that ships (ADR 0007 D1): the router, then the query against the datasets it chose.
      class Routed
        def initialize(llm:, router_llm:, time_zone:)
          @llm = llm
          @pipeline = Pipeline.new(llm: llm, router_llm: router_llm)
          @time_zone = time_zone
        end

        def name = "routed #{@llm.respond_to?(:model) ? @llm.model : @llm.class.name}"
        def fingerprint = "router #{Router.fingerprint} prompt #{Prompt.fingerprint}"

        def call(request)
          result = @pipeline.call(request.text, catalog: Catalog.for(request.role), today: request.today, time_zone: @time_zone)
          Response.new(output: result.output, input_tokens: result.input_tokens, output_tokens: result.output_tokens, latency_ms: result.latency_ms,
                       cached_input_tokens: result.cached_input_tokens, model: result.model, route: result.route)
        rescue *ANSWER_FAILURES => e
          Response.new(output: nil, input_tokens: 0, output_tokens: 0, latency_ms: 0, failure: e.class.name.demodulize)
        end
      end
    end
  end
end
