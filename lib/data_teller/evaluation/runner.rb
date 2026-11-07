require "json"

module DataTeller
  module Evaluation
    # Asks a model every question of a set, in each language, and scores each answer (T11).
    class Runner
      Result = Data.define(:id, :language, :tags, :score, :response)

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
                       response: response)
          end
        end
      end

      private

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
