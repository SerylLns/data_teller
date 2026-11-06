require "date"

module DataTeller
  # The check that counts: the LLM's output is untrusted, whatever schema it was given (ADR 0004 D5). A query is judged only
  # against what the role can see, so a forbidden name and an unknown one are the same case, with the same refusal (ADR 0001 D5).
  #
  # `problems` is for logs and the eval. It holds JSON pointers and codes, never the names the LLM wrote, and it never reaches
  # the user: what they see comes from `refusal.reason`, through a translated template.
  class QueryValidator
    Refusal = Data.define(:reason)
    Result = Data.define(:query, :refusal, :problems) do
      def ok? = refusal.nil?
    end

    EQUALITY = %w[eq not_eq in not_in is_null is_not_null].freeze
    OPERATORS = {
      enum: EQUALITY,
      boolean: EQUALITY,
      string: EQUALITY + %w[contains],
      number: EQUALITY + %w[gt gte lt lte]
    }.freeze
    LOOKUP_OPERATORS = %w[eq not_eq in not_in].freeze

    # Most specific first: an unknown dataset explains everything that follows it.
    REASON_PRIORITY = %i[unknown_dataset unknown_metric too_many_groups unsupported_query].freeze

    def initialize(catalog)
      @catalog = catalog
    end

    def call(query)
      @problems = []
      check(query)

      Result.new(query: query, refusal: refusal_from_problems, problems: @problems.freeze)
    end

    private

    def check(query)
      return problem("", :invalid_structure) unless QuerySchema.valid?(query)

      case query["intent"]
      when "answer" then check_answer(query)
      when "clarify" then check_clarify(query)
      end
    end

    def refusal_from_problems
      return nil if @problems.empty?

      Refusal.new(reason: REASON_PRIORITY.find { |reason| @problems.any? { |problem| problem[:reason] == reason } })
    end

    def problem(pointer, code, reason: :unsupported_query)
      @problems << { pointer: pointer, code: code, reason: reason }
    end

    def check_answer(query)
      entry = @catalog.datasets.find { |candidate| candidate.name.to_s == query["dataset"] }
      return problem("/dataset", :unknown_dataset, reason: :unknown_dataset) unless entry

      unless entry.metrics.any? { |metric| metric.name.to_s == query["metric"] }
        problem("/metric", :unknown_metric, reason: :unknown_metric)
      end

      check_period(entry, query["period"]) if query["period"]
      Array(query["filters"]).each_with_index { |filter, index| check_filter(entry, filter, "/filters/#{index}") }
      check_group_by(entry, Array(query["group_by"]))
      check_order_by(query["order_by"], Array(query["group_by"])) if query["order_by"]
    end

    def field(entry, name)
      entry.fields.find { |candidate| candidate.name.to_s == name }
    end

    def check_period(entry, period)
      found = field(entry, period["dimension"])
      problem("/period/dimension", :not_a_period_dimension) unless found&.period?

      range = period["range"]
      if range["on"]
        problem("/period/range/on", :impossible_date) unless real_date(range["on"])
      elsif range["between"]
        check_between(range["between"])
      end
    end

    def check_between(between)
      from = real_date(between["from"])
      to = real_date(between["to"])

      if from.nil? || to.nil?
        problem("/period/range/between", :impossible_date)
      elsif from > to
        problem("/period/range/between", :range_ends_before_it_starts)
      end
    end

    # The schema's pattern cannot know that February has no 31st.
    def real_date(text)
      Date.iso8601(text)
    rescue Date::Error
      nil
    end

    def check_filter(entry, filter, at)
      if filter.key?("segment")
        return if entry.segments.any? { |segment| segment.name.to_s == filter["segment"] }

        return problem("#{at}/segment", :unknown_segment)
      end

      found = field(entry, filter["dimension"])
      return problem("#{at}/dimension", :unknown_dimension) unless found
      return problem("#{at}/dimension", :not_filterable) unless found.filterable?

      check_operator_and_value(found, filter, at)
    end

    def check_operator_and_value(found, filter, at)
      kind = found.kind
      problem("#{at}/op", :operator_not_allowed) unless OPERATORS.fetch(kind).include?(filter["op"])
      return unless filter.key?("value")

      Array.wrap(filter["value"]).each { |value| check_value(found, kind, filter["op"], value, at) }
    end

    def check_value(found, kind, operator, value, at)
      return check_lookup(found, operator, at) if value.is_a?(Hash)

      # A raw string misses accents and hides homonyms: an entity is matched through a lookup (ADR 0001 D2).
      if found.dimension.lookup && LOOKUP_OPERATORS.include?(operator)
        return problem("#{at}/value", :lookup_required)
      end

      problem("#{at}/value", :invalid_character) if value.is_a?(String) && value.include?("\u0000")
      problem("#{at}/value", :wrong_value_type) unless value_fits?(found, kind, value)
    end

    # A NUL byte is refused here because the database driver raises on it, and it can come straight from the LLM.
    def check_lookup(found, operator, at)
      problem("#{at}/value", :lookup_not_allowed) unless found.dimension.lookup && LOOKUP_OPERATORS.include?(operator)
    end

    def value_fits?(found, kind, value)
      case kind
      when :enum then value.is_a?(String) && (found.enum_values.nil? || found.enum_values.include?(value))
      when :boolean then value == true || value == false
      when :number then value.is_a?(Numeric) && (!found.integer? || value == value.to_i)
      else value.is_a?(String)
      end
    end

    def check_group_by(entry, items)
      fields = items.each_with_index.map do |item, index|
        check_group_item(entry, item, "/group_by/#{index}")
      end.compact

      problem("/group_by", :duplicate_dimension) if items.map { |item| item["dimension"] }.uniq.size < items.size
      return unless fields.count(&:high_cardinality?) > 1

      problem("/group_by", :two_high_cardinality_dimensions, reason: :too_many_groups)
    end

    def check_group_item(entry, item, at)
      found = field(entry, item["dimension"])
      unless found&.groupable?
        problem("#{at}/dimension", :not_groupable)
        return nil
      end

      if found.date? && !item["granularity"]
        problem(at, :date_needs_granularity)
      elsif !found.date? && item["granularity"]
        problem("#{at}/granularity", :granularity_not_allowed)
      end
      found
    end

    # SQL would refuse anything else on an aggregate, and ordering by a hidden column would reveal its values.
    def check_order_by(order_by, group_items)
      return unless order_by["by"] == "dimension"
      return if group_items.any? { |item| item["dimension"] == order_by["dimension"] }

      problem("/order_by/dimension", :order_by_not_grouped)
    end

    def check_clarify(query)
      visible = @catalog.datasets.flat_map do |entry|
        [ entry.name, *entry.metrics.map(&:name), *entry.fields.map(&:name), *entry.segments.map(&:name) ]
      end.map(&:to_s)

      query["clarify"]["options"].each_with_index do |option, index|
        problem("/clarify/options/#{index}", :unknown_option) unless visible.include?(option)
      end
    end
  end
end
