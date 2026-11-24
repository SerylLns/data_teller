module DataTeller
  # A compiled list (ADR 0016): rows of one dataset, a page at a time. It shares with Plan what the isolation kit reads (touched,
  # row_keys, tables_read), so a list is proved like an aggregate.
  class ListPlan < Plan
    # rows: the page, decoded. total: how many rows the list has, capped by the query's limit, on the first page only (nil after).
    # after: the cursor of the next page, nil on the last one. The client sends it back as is; it is checked again (Compiler).
    Result = Data.define(:columns, :rows, :total, :after, :period) do
      def list? = true
    end

    # keys: the order column (nil when the dataset has none) and the primary key, as Arel attributes with their decoders, read on each
    # row only to build the cursor. page: rows on this page. shown: rows on the pages before. cap: the query's limit, nil when none.
    def initialize(relation:, columns:, selection:, decoders:, keys:, page:, shown:, cap:, counted:, period: nil, touched: [])
      super(relation: relation, columns: columns, selection: selection, decoders: decoders, limit: page, period: period, touched: touched)
      @keys = keys
      @shown = shown
      @cap = cap
      @counted = counted
    end

    def to_sql
      limited.select(*aliased_selection).to_sql
    end

    def statements
      [ to_sql, (counting_sql if first_page?) ].compact
    end

    def execute(recorder: nil)
      raw = raw_rows(recorder)
      shown = raw.first(@limit)
      more = raw.size > @limit && !capped_after?(shown.size)

      Result.new(columns: @columns, rows: shown.map { |row| decode(row.first(@columns.size)) }, total: (total(recorder) if first_page?),
                 after: (cursor(shown.last) if more && shown.any?), period: @period)
    end

    # Never grouped, so never under a minimum group size: the validator refuses a list where one applies (ADR 0016 D3).
    def protected? = false
    def grouped? = false

    private

    def first_page? = @shown.zero?
    def capped_after?(count) = @cap && @shown + count >= @cap

    def counting_sql = @counted.select(Arel.star.count).to_sql

    # COUNT over the same relation, ordering and paging left out: the total of the list the user asked for, at most its limit.
    def total(recorder)
      recorder&.call(counting_sql)
      ReadOnlyExecution.before_statement
      count = @counted.count
      @cap ? [ count, @cap ].min : count
    end

    # What the next page needs: the order value as the user would write it in a filter, the primary key, and how many rows came before.
    def cursor(row)
      values = row.last(@keys.size).each_with_index.map { |raw, index| @keys[index].call(raw) }
      { "values" => values, "shown" => @shown + @limit }
    end
  end
end
