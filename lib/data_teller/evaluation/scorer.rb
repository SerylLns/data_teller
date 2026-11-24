module DataTeller
  module Evaluation
    # Right or wrong per question, and what kind of wrong (ADR 0006 D4). Carries the question's id only, never its text nor the
    # model's output: a held-out question must not feed back into tuning through a report.
    class Scorer
      SEVERITY = {
        wrong_answer: :high, answered_out_of_scope: :high,
        unnecessary_clarification: :medium, missed_clarification: :medium, clarified_out_of_scope: :medium,
        wrong_clarification: :low, wrongful_refusal: :low, wrong_reason: :low, invalid_output: :low
      }.freeze

      ANSWER_FIELDS = %w[dataset metric list columns filters group_by period order_by limit compare].freeze

      # fields: for two answers, which ones match the expected query. same_result: a wrong answer that returns the rows of an
      # accepted one, which is usually a missing also_accepted. nil when not checked.
      Score = Data.define(:id, :correct, :error, :severity, :fields, :same_result)

      # executor: optional, runs an answer on the seeds and returns its rows, for same_result.
      def initialize(today:, time_zone:, executor: nil)
        @today = today
        @time_zone = time_zone
        @executor = executor
      end

      def call(question, output)
        catalog = Catalog.for(question.role)
        return score(question, :invalid_output) unless output.is_a?(Hash) && QueryValidator.new(catalog).call(output).ok?

        normalizer = Normalizer.new(catalog: catalog, today: @today, time_zone: @time_zone)
        given = normalizer.call(output)
        accepted = question.accepted.map { |query| normalizer.call(query) }
        return score(question, nil, fields: fields(accepted.first, given)) if accepted.include?(given)

        error = error_for(question.expected["intent"], output["intent"])
        score(question, error, fields: fields(accepted.first, given), same_result: same_result(question, output, error))
      end

      private

      def score(question, error, fields: nil, same_result: nil)
        Score.new(id: question.id, correct: error.nil?, error: error, severity: error && SEVERITY.fetch(error), fields: fields, same_result: same_result)
      end

      def error_for(expected, given)
        case [ expected, given ]
        in [ "answer", "answer" ] then :wrong_answer
        in [ "answer", "clarify" ] then :unnecessary_clarification
        in [ "clarify", "answer" ] then :missed_clarification
        in [ "clarify", "clarify" ] then :wrong_clarification
        in [ "out_of_scope", "answer" ] then :answered_out_of_scope
        in [ "out_of_scope", "clarify" ] then :clarified_out_of_scope
        in [ "out_of_scope", "out_of_scope" ] then :wrong_reason
        in [ _, "out_of_scope" ] then :wrongful_refusal
        end
      end

      def fields(expected, given)
        return nil unless expected["intent"] == "answer" && given["intent"] == "answer"

        ANSWER_FIELDS.to_h { |field| [ field.to_sym, expected[field] == given[field] ] }
      end

      def same_result(question, output, error)
        return nil unless @executor && error == :wrong_answer

        rows = @executor.call(question, output)
        !rows.nil? && question.accepted.select { |query| query["intent"] == "answer" }.any? { |query| @executor.call(question, query) == rows }
      end
    end
  end
end
