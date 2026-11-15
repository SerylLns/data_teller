module DataTeller
  # A compiled query, ready to run. Reading its SQL runs nothing, which is what the tests and later the explanation rely on.
  class Plan
    # period and compared_period are two dates, the end being exclusive. nil when the query has none.
    # suppressed: the groups left out because they were under a minimum group size (ADR 0012 D3).
    Result = Data.define(:columns, :rows, :truncated, :period, :compared_period, :suppressed) do
      # The single number of a query with no group_by.
      def value = rows.first&.at(compared_period ? -2 : -1)
      def previous_value = compared_period ? rows.first&.last : nil
    end

    # series: the indexes of the date columns and the maximum number of time points, for a series the user did not cap.
    Series = Data.define(:columns, :max_points)

    # The rows behind an answer, for the isolation kit (ADR 0011 D5): one primary key per dataset of `datasets`, in that order.
    # unkeyed: the touched datasets with no single primary key, which no row can be checked for.
    RowKeys = Data.define(:datasets, :rows, :truncated, :unkeyed)

    # touched: the datasets the compiler applied a tenant filter for, the dataset's own one last. big_enough: the HAVING condition of the
    # minimum group sizes that apply, nil when none does (ADR 0012).
    def initialize(relation:, columns:, selection:, decoders:, limit:, series: nil, period: nil, touched: [], big_enough: nil)
      @touched = touched
      @big_enough = big_enough
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
                     selection: @selection, decoders: @decoders, limit: nil, period: @period, touched: @touched, big_enough: @big_enough)
    end

    def to_sql
      limited.select(*aliased_selection).to_sql
    end

    # recorder, when given, receives the SQL before it runs (QueryRunner's trace).
    def execute(recorder: nil)
      raw = raw_rows(recorder)
      raise Compiler::Refused.new(:group_too_small) if too_small?(raw)
      raise Compiler::Refused.new(:too_many_groups) if series_too_long?(raw)

      Result.new(columns: @columns, rows: kept(raw).map { |row| decode(row) }, truncated: truncated?(raw), period: @period, compared_period: nil,
                 suppressed: suppressed(recorder))
    end

    def protected? = !@big_enough.nil?
    def grouped? = @relation.group_values.any?

    # Without group_by an aggregate always returns one row, 0 when nothing matches; the HAVING turns it into none. So no row is a single
    # value under the threshold, zero included, never "0 orders" (ADR 0012 D4).
    def too_small?(raw) = protected? && !grouped? && raw.empty?

    # The groups the HAVING left out, counted apart: the answer cannot hold them. Their labels and values never leave the database.
    def suppressed(recorder = nil)
      return 0 unless protected? && grouped?

      small = @relation.unscope(:having, :order).having(Arel::Nodes::Not.new(@big_enough)).select(Arel.sql("1"))
      counting = @relation.klass.unscoped.from(small.arel.as("small_groups"))
      recorder&.call(counting.select(Arel.star.count).to_sql)
      ReadOnlyExecution.before_statement
      counting.count
    end

    # As returned by the database, with the extra row that tells a result was cut. ComparedPlan works on these: groups line up
    # on their stored values.
    def raw_rows(recorder = nil)
      recorder&.call(to_sql)
      ReadOnlyExecution.before_statement
      raw = limited.pluck(*aliased_selection)
      @selection.one? ? raw.map { |value| [ value ] } : raw
    end

    def kept(raw) = raw.first(@limit || raw.size)
    def truncated?(raw) = !@limit.nil? && raw.size > @limit
    def decode(row) = row.each_with_index.map { |value, index| @decoders[index] ? @decoders[index].call(value) : value }
    def metric_decoder = @decoders.last
    attr_reader :columns, :period, :touched

    # ---- for the isolation kit only (ADR 0011 D5): no field of a query leads here.

    def plans = [ self ]

    # Every row the aggregate reads, not the groups it returns: the query's own limit caps groups, so it does not apply here.
    def row_keys(cap:)
      keyed, unkeyed = @touched.partition { |dataset| dataset.model_name.constantize.primary_key.is_a?(String) }
      return RowKeys.new(datasets: [], rows: [], truncated: false, unkeyed: unkeyed) if keyed.empty?

      keys = keyed.map { |dataset| dataset.model_name.constantize.then { |model| model.arel_table[model.primary_key] } }
      # The HAVING of a minimum group size goes too: the aggregate reads the rows of the small groups, so they are checked.
      ReadOnlyExecution.before_statement
      raw = @relation.unscope(:group, :order, :having).limit(cap + 1).pluck(*keys)
      raw = raw.map { |key| [ key ] } if keys.one?

      RowKeys.new(datasets: keyed, rows: raw.first(cap), truncated: raw.size > cap, unkeyed: unkeyed)
    end

    # Read from the relation, not from `touched`: the kit compares the two, since a table missing from `touched` has no tenant
    # filter either. Anything but a plain table (an alias, a sub-query, SQL text) comes out as "not a table" and matches no dataset.
    def tables_read
      arel = @relation.arel

      [ arel.source.left, *arel.join_sources.map(&:left) ].map do |source|
        source.is_a?(Arel::Table) && source.table_alias.nil? ? source.name : "(not a table: #{source.class.name})"
      end
    end

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
