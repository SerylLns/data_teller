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
          "usage" => usage,
          "routing" => routing
        }.compact
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
        if (routing = data["routing"])
          lines << "Routing: " + routing["within"].map { |datasets, rate| "within #{datasets} #{label(rate)}" }.join(", ")
          lines << "  route missed: #{routing['missed'].join(', ')}" if routing["missed"].any?
        end
        usage = data["usage"]
        lines << "Tokens: #{usage['input_tokens']} in (#{usage['cached_input_tokens']} cached), #{usage['output_tokens']} out; " \
                 "latency median #{usage['latency_ms_median']} ms"
        lines << "Answered by: #{usage['answered_by'].join(', ')}" if usage["answered_by"].any?
        lines << "Failures: #{usage['failures'].map { |failure, count| "#{failure} #{count}" }.join(', ')}" if usage["failures"].any?
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

      # Retrieval is scored apart from generation (project rule): was the right dataset among the first 1, 2, 3 chosen? Numbers and ids
      # only, so that it can stand in a held-out report.
      def routing
        routed = @results.select(&:route_rank)
        return nil if routed.empty?

        {
          "within" => (1..Router::MAX_DATASETS).to_h do |datasets|
            right = routed.count { |result| result.route_rank.between?(1, datasets) }
            [ datasets.to_s, { "right" => right, "total" => routed.size, "percent" => (100.0 * right / routed.size).round(1) } ]
          end,
          "missed" => routed.select { |result| result.route_rank.zero? }.map { |result| key(result) }
        }
      end

      def usage
        latencies = @results.map { |result| result.response.latency_ms }.sort
        {
          "input_tokens" => @results.sum { |result| result.response.input_tokens },
          "cached_input_tokens" => @results.sum { |result| result.response.cached_input_tokens },
          "output_tokens" => @results.sum { |result| result.response.output_tokens },
          "latency_ms_median" => latencies.empty? ? 0 : latencies[latencies.size / 2],
          # An alias can move to another model during a run: every name answered with is listed.
          "answered_by" => @results.filter_map { |result| result.response.model }.uniq.sort,
          "failures" => @results.filter_map { |result| result.response.failure }.tally.sort.to_h
        }
      end

      def answer(result)
        score = result.score
        entry = {
          "id" => result.id, "language" => result.language, "correct" => score.correct, "error" => score.error&.to_s,
          "severity" => score.severity&.to_s, "differs_on" => score.fields&.reject { |_field, same| same }&.keys&.map(&:to_s),
          "same_result" => score.same_result, "input_tokens" => result.response.input_tokens,
          "cached_input_tokens" => result.response.cached_input_tokens, "output_tokens" => result.response.output_tokens,
          "latency_ms" => result.response.latency_ms, "answered_by" => result.response.model, "failure" => result.response.failure
        }
        entry["route_rank"] = result.route_rank if result.response.route
        return entry if @held_out

        entry["route"] = result.response.route if result.response.route
        entry.merge("output" => result.response.output)
      end
    end
  end
end
