module DataTeller
  module Evaluation
    # The numbers of a run (ADR 0006 D4): the headline score, by language and by tag, errors by class and severity, what to review,
    # and the cost. A held-out run keeps ids and numbers only: no question text and no model output reach whoever reads it.
    class Report
      def initialize(results, split:, model:, held_out:, now: Time.current)
        @results = results
        @split = split
        @model = model
        @held_out = held_out
        @now = now
      end

      def summary
        {
          "score" => rate(@results),
          "by_language" => @results.group_by(&:language).transform_values { |results| rate(results) },
          "by_tag" => @results.flat_map { |result| result.tags.map { |tag| [ tag, result ] } }.group_by(&:first)
                              .transform_values { |pairs| rate(pairs.map(&:last)) }.sort.to_h,
          "errors" => wrong.group_by { |result| result.score.error.to_s }.transform_values(&:size).sort.to_h,
          "by_severity" => wrong.group_by { |result| result.score.severity.to_s }.transform_values(&:size),
          "to_review" => wrong.select { |result| result.score.same_result }.map { |result| key(result) },
          "usage" => usage
        }
      end

      # What is saved and committed, one file per run.
      def to_h
        {
          "split" => @split, "model" => @model.name, "fingerprint" => @model.fingerprint, "ran_at" => @now.iso8601,
          "held_out" => @held_out, "summary" => summary,
          "answers" => @results.map { |result| answer(result) }
        }
      end

      def to_text
        data = summary
        lines = [ "DataTeller eval: #{@split}, model #{@model.name}, #{@results.map(&:id).uniq.size} questions, #{@results.size} answers" ]
        lines << "Score: #{label(data['score'])}   " + data["by_language"].map { |language, rate| "#{language} #{label(rate)}" }.join("   ")
        lines << "By tag: " + data["by_tag"].map { |tag, rate| "#{tag} #{label(rate)}" }.join(", ")
        lines << "Errors: " + (data["errors"].empty? ? "none" : data["errors"].map { |error, count| "#{error} #{count} (#{Scorer::SEVERITY.fetch(error.to_sym)})" }.join(", "))
        wrong.each { |result| lines << "  #{key(result)}: #{result.score.error}#{fields_note(result)}#{' — same rows as an accepted query, to review' if result.score.same_result}" }
        lines << "Tokens: #{data['usage']['input_tokens']} in, #{data['usage']['output_tokens']} out; latency median #{data['usage']['latency_ms_median']} ms"
        lines.join("\n") + "\n"
      end

      private

      def wrong = @results.reject { |result| result.score.correct }
      def key(result) = "#{result.id}/#{result.language}"

      def rate(results)
        right = results.count { |result| result.score.correct }
        { "right" => right, "total" => results.size, "percent" => results.empty? ? 0.0 : (100.0 * right / results.size).round(1) }
      end

      def label(rate) = "#{rate['percent']}% (#{rate['right']}/#{rate['total']})"

      # Field names only, which the catalog already has: never a value the model wrote.
      def fields_note(result)
        differing = result.score.fields&.reject { |_field, same| same }&.keys
        differing.blank? ? "" : ", differs on #{differing.join(', ')}"
      end

      def usage
        latencies = @results.map { |result| result.response.latency_ms }.sort
        {
          "input_tokens" => @results.sum { |result| result.response.input_tokens },
          "output_tokens" => @results.sum { |result| result.response.output_tokens },
          "latency_ms_median" => latencies.empty? ? 0 : latencies[latencies.size / 2]
        }
      end

      def answer(result)
        score = result.score
        entry = {
          "id" => result.id, "language" => result.language, "correct" => score.correct, "error" => score.error&.to_s,
          "severity" => score.severity&.to_s, "differs_on" => score.fields&.reject { |_field, same| same }&.keys&.map(&:to_s),
          "same_result" => score.same_result, "input_tokens" => result.response.input_tokens,
          "output_tokens" => result.response.output_tokens, "latency_ms" => result.response.latency_ms
        }
        @held_out ? entry : entry.merge("output" => result.response.output)
      end
    end
  end
end
