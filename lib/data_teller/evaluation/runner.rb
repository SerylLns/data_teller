require "json"

module DataTeller
  module Evaluation
    # Asks a model every question of a set, in each language, and scores each answer (T11).
    class Runner
      # route_rank: where a router put the right dataset, 1 being first and 0 not at all; nil when there is no router or no dataset to find.
      Result = Data.define(:id, :language, :tags, :score, :response, :route_rank)

      def initialize(set:, model:, scorer:, languages: QuestionSet::LANGUAGES)
        @set = set
        @model = model
        @scorer = scorer
        @languages = languages
      end

      def call
        @set.questions.flat_map do |question|
          @languages.map do |language|
            response = @model.call(Request.new(id: question.id, language: language, text: question.text.fetch(language),
                                               role: question.role, today: @set.today))
            Result.new(id: question.id, language: language, tags: question.tags, score: @scorer.call(question, parsed(response.output)),
                       response: response, route_rank: route_rank(question, response.route))
          end
        end
      end

      private

      # Scored over the questions expecting an answer: a clarification or a refusal has no right dataset (ADR 0007 D1).
      def route_rank(question, route)
        return nil unless route

        right = question.accepted.select { |query| query["intent"] == "answer" }.map { |query| query["dataset"] }
        return nil if right.empty?

        index = route.index { |dataset| right.include?(dataset) }
        index ? index + 1 : 0
      end

      # A model may answer with JSON text: what does not parse stays a string, and scores as invalid_output.
      def parsed(output)
        return output unless output.is_a?(String)

        JSON.parse(output)
      rescue JSON::ParserError
        output
      end
    end
  end
end
