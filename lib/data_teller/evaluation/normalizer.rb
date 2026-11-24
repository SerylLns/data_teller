module DataTeller
  module Evaluation
    # Two queries that mean the same thing, written the same way (ADR 0006 D4). Each rule is one the compiler itself makes true:
    # nothing here guesses what the model meant. Takes valid queries only: the scorer checks them first.
    class Normalizer
      def initialize(catalog:, today:, time_zone:)
        @catalog = catalog
        # Midday: the day is the same in every time zone a tenant can have.
        @periods = PeriodResolver.new(time_zone: time_zone, now: time_zone.local(today.year, today.month, today.day, 12))
      end

      def call(query)
        case query["intent"]
        when "answer" then query["list"] ? list(query) : answer(query)
        when "clarify" then { "intent" => "clarify", "reason" => query["clarify"]["reason"], "options" => query["clarify"]["options"].sort }
        else { "intent" => query["intent"], "reason" => query.dig("out_of_scope", "reason") }
        end
      end

      private

      def answer(query)
        {
          "intent" => "answer",
          "dataset" => query["dataset"],
          "metric" => query["metric"],
          "filters" => Array(query["filters"]).map { |filter| filter_key(filter) }.sort_by(&:to_s),
          # The same groups in another order are the same rows, in other columns.
          "group_by" => Array(query["group_by"]).map { |item| [ item["dimension"], item["granularity"] ] }.sort_by(&:to_s),
          "period" => query["period"] && [ query["period"]["dimension"], *@periods.call(query["period"]["range"]) ],
          "order_by" => ordering(query),
          "limit" => query["limit"],
          "compare" => query["compare"]
        }
      end

      # ADR 0016: the same rows in the same columns. No columns means the defaults the role sees, as the compiler reads it; their order
      # is presentation. Without a limit every row comes back, so the order is presentation too, as for an aggregate.
      def list(query)
        {
          "intent" => "answer",
          "dataset" => query["dataset"],
          "list" => true,
          "columns" => list_columns(query).sort,
          "filters" => Array(query["filters"]).map { |filter| filter_key(filter) }.sort_by(&:to_s),
          "period" => query["period"] && [ query["period"]["dimension"], *@periods.call(query["period"]["range"]) ],
          "order_by" => query["limit"] && list_order(query),
          "limit" => query["limit"]
        }
      end

      def list_columns(query)
        return query["columns"] if query["columns"]

        entry = @catalog.dataset(query["dataset"])
        visible = entry.fields.map { |field| field.name.to_s }
        entry.dataset.list.default.map(&:to_s) & visible
      end

      # The compiler's default: the dataset's own default date, newest first.
      def list_order(query)
        return [ query["order_by"]["dimension"], query["order_by"]["dir"] ] if query["order_by"]

        default = @catalog.dataset(query["dataset"]).fields.find { |field| field.steps.empty? && field.dimension.time }
        default && [ default.name.to_s, "desc" ]
      end

      def filter_key(filter)
        return [ "segment", filter["segment"] ] if filter["segment"]

        op = filter["op"]
        value = filter["value"]
        if %w[in not_in].include?(op) && value.size == 1
          op = op == "in" ? "eq" : "not_eq"
          value = value.first
        end
        value = value.sort_by(&:to_s) if value.is_a?(Array)

        [ "dimension", filter["dimension"], op, value ]
      end

      # An order matters when it decides which rows a limit keeps. The compiler orders a high-cardinality group by the metric,
      # descending, when nothing is asked; with no limit and no such group, every row comes back and the order is presentation.
      def ordering(query)
        order_by = query["order_by"]
        return nil if order_by.nil?

        high_cardinality = high_cardinality_group?(query)
        return nil if high_cardinality && order_by["by"] == "metric" && order_by["dir"] == "desc"
        return nil if !high_cardinality && query["limit"].nil?

        [ order_by["by"], order_by["dimension"], order_by["dir"] ]
      end

      def high_cardinality_group?(query)
        entry = @catalog.dataset(query["dataset"])
        Array(query["group_by"]).any? do |item|
          field = entry&.fields&.find { |candidate| candidate.name.to_s == item["dimension"] }
          field&.high_cardinality?
        end
      end
    end
  end
end
