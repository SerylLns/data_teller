require "yaml"

module DataTeller
  module Evaluation
    # A file of evaluation questions (ADR 0006): the day they are asked on, the tenant, and each question with the query expected.
    class QuestionSet
      LANGUAGES = %w[en fr].freeze

      Question = Data.define(:id, :role, :text, :tags, :expected, :also_accepted) do
        # What scores as right: the expected query, or one of the others the file accepts.
        def accepted = [ expected, *also_accepted ]
      end

      attr_reader :today, :tenant, :questions

      def self.load(path) = new(YAML.safe_load_file(path))

      def initialize(data)
        @today = Date.iso8601(data.fetch("today"))
        @tenant = data.fetch("tenant")
        @questions = data.fetch("questions").map { |question| build(question) }.freeze
      end

      private

      def build(question)
        Question.new(
          id: question.fetch("id"),
          role: question.fetch("role", "admin").to_sym,
          text: LANGUAGES.to_h { |language| [ language, question.fetch(language) ] }.freeze,
          tags: Array(question["tags"]).freeze,
          expected: question.fetch("expected"),
          also_accepted: Array(question["also_accepted"]).freeze
        )
      end
    end
  end
end
