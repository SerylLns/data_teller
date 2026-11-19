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

    # For the cost estimate (ADR 0013 D3). The previous period of a grouped compare is narrowed to the groups shown, known only once the
    # current one ran: it is estimated whole, which reads at least the same rows.
    def statements
      previous = @group_columns.empty? ? @previous : @previous.narrowed_to([])
      @current.statements + [ previous.to_sql ]
    end

    def execute(recorder: nil)
      raw = @current.raw_rows(recorder)
      raise Compiler::Refused.new(:group_too_small) if @current.too_small?(raw)

      kept = @current.kept(raw)
      earlier = previous_values(kept, recorder)
      # Under a minimum group size, a group with no previous row was small then, or absent: its change would give the hidden value by a
      # subtraction, so the group goes, not only its previous value (ADR 0012 D4).
      shown = @current.protected? ? kept.select { |row| earlier.key?(row[0...-1]) } : kept

      rows = shown.map do |row|
        previous = earlier[row[0...-1]]
        @current.decode(row) + [ decode_metric(previous) ]
      end

      Plan::Result.new(columns: @current.columns + [ "previous_#{@metric_name}" ], rows: rows, truncated: @current.truncated?(raw),
                       period: @current.period, compared_period: @previous.period,
                       suppressed: @current.suppressed(recorder) + kept.size - shown.size)
    end

    private

    # Narrowed to the groups being shown rather than cut by rank: a group's previous value must not depend on how it ranked then.
    def previous_values(kept, recorder)
      if @group_columns.empty?
        previous = @previous.raw_rows(recorder)
        raise Compiler::Refused.new(:group_too_small) if @previous.too_small?(previous)

        return { [] => previous.first&.last }
      end
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
