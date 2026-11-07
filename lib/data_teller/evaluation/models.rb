require "json"

module DataTeller
  module Evaluation
    # What `rake data_teller:eval` asks a model, and what it gets back (T11). A real LLM adapter (T12) takes the same request: the
    # question's text, never its expected query.
    Request = Data.define(:id, :language, :text, :role, :today)
    Response = Data.define(:output, :input_tokens, :output_tokens, :latency_ms)

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
                       latency_ms: answer["latency_ms"].to_i)
        end
      end
    end
  end
end
