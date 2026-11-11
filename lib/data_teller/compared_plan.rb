module DataTeller
  # A query and the same query on the previous period (ADR 0005 D4). Each has its own tenant filter and its own check: they are
  # two full plans from the compiler. The result follows the current period: its top N, with each group's previous value.
  class ComparedPlan
    def initialize(current:, previous:, group_columns:, metric_name:)
      @current = current
      @previous = previous
      @group_columns = group_columns
      @metric_name = metric_name
    end

    # For the isolation kit (ADR 0011 D5): both periods are checked.
    def plans = [ @current, @previous ]

    def execute(recorder: nil)
      raw = @current.raw_rows(recorder)
      kept = @current.kept(raw)
      earlier = previous_values(kept, recorder)

      rows = kept.map do |row|
        previous = earlier[row[0...-1]]
        @current.decode(row) + [ decode_metric(previous) ]
      end

      Plan::Result.new(columns: @current.columns + [ "previous_#{@metric_name}" ], rows: rows, truncated: @current.truncated?(raw),
                       period: @current.period, compared_period: @previous.period)
    end

    private

    # Narrowed to the groups being shown rather than cut by rank: a group's previous value must not depend on how it ranked then.
    def previous_values(kept, recorder)
      return { [] => @previous.raw_rows(recorder).first&.last } if @group_columns.empty?
      return {} if kept.empty?

      @previous.narrowed_to(group_conditions(kept)).raw_rows(recorder).to_h { |row| [ row[0...-1], row.last ] }
    end

    def group_conditions(kept)
      @group_columns.each_with_index.map do |(model, column), index|
        values = kept.map { |row| row[index] }.uniq
        attribute = model.arel_table[column]
        listed = attribute.in(values.compact.map { |value| Compiler.bind(model, column, value) })

        values.include?(nil) ? Arel::Nodes::Grouping.new(listed.or(attribute.eq(nil))) : listed
      end
    end

    def decode_metric(value)
      decoder = @current.metric_decoder
      decoder ? decoder.call(value) : value
    end
  end
end
