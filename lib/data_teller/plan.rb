module DataTeller
  # A compiled query, ready to run. Reading its SQL runs nothing, which is what the tests and later the explanation rely on.
  class Plan
    # period and compared_period are two dates, the end being exclusive. nil when the query has none.
    Result = Data.define(:columns, :rows, :truncated, :period, :compared_period) do
      # The single number of a query with no group_by.
      def value = rows.first&.at(compared_period ? -2 : -1)
      def previous_value = compared_period ? rows.first&.last : nil
    end

    # series: the indexes of the date columns and the maximum number of time points, for a series the user did not cap.
    Series = Data.define(:columns, :max_points)

    def initialize(relation:, columns:, selection:, decoders:, limit:, series: nil, period: nil)
      @series = series
      @period = period
      @relation = relation
      @columns = columns
      @selection = selection
      @decoders = decoders
      @limit = limit
    end

    # The same plan, on fewer rows and with no cap: the conditions come on top, so the tenant filter stays.
    def narrowed_to(conditions)
      self.class.new(relation: conditions.reduce(@relation) { |current, condition| current.where(condition) }, columns: @columns,
                     selection: @selection, decoders: @decoders, limit: nil, period: @period)
    end

    def to_sql
      limited.select(*aliased_selection).to_sql
    end

    def execute
      raw = raw_rows
      raise Compiler::Refused.new(:too_many_groups) if series_too_long?(raw)

      Result.new(columns: @columns, rows: kept(raw).map { |row| decode(row) }, truncated: truncated?(raw), period: @period, compared_period: nil)
    end

    # As returned by the database, with the extra row that tells a result was cut. ComparedPlan works on these: groups line up
    # on their stored values.
    def raw_rows
      raw = limited.pluck(*aliased_selection)
      @selection.one? ? raw.map { |value| [ value ] } : raw
    end

    def kept(raw) = raw.first(@limit || raw.size)
    def truncated?(raw) = !@limit.nil? && raw.size > @limit
    def decode(row) = row.each_with_index.map { |value, index| @decoders[index] ? @decoders[index].call(value) : value }
    def metric_decoder = @decoders.last
    attr_reader :columns, :period

    private

    # Counted on the dates, not the rows: by status and by day, 90 days is 90 points on 450 rows. Cutting would hide the end.
    def series_too_long?(raw)
      return false unless @series

      truncated?(raw) || raw.map { |row| row.values_at(*@series.columns) }.uniq.size > @series.max_points
    end

    # Aliased so that pluck reads what the database returned. Otherwise it casts a column through the root model's attribute
    # of the same name, which is wrong as soon as a joined table has a column named like one of the root's.
    def aliased_selection
      @selection.each_with_index.map { |node, index| node.as("c#{index}") }
    end

    # One row more than asked: it is how a result knows it was cut.
    def limited
      @limit ? @relation.limit(@limit + 1) : @relation
    end
  end
end
