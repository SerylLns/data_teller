module DataTeller
  # A compiled query, ready to run. Reading its SQL runs nothing, which is what the tests and later the explanation rely on.
  class Plan
    Result = Data.define(:columns, :rows, :truncated) do
      # The single number of a query with no group_by.
      def value = rows.first&.last
    end

    # refuse_when_cut: a date series beyond its cap is refused rather than truncated (ADR 0004 D3).
    def initialize(relation:, columns:, selection:, decoders:, limit:, refuse_when_cut: false)
      @refuse_when_cut = refuse_when_cut
      @relation = relation
      @columns = columns
      @selection = selection
      @decoders = decoders
      @limit = limit
    end

    def to_sql
      limited.select(*aliased_selection).to_sql
    end

    def execute
      raw = limited.pluck(*aliased_selection)
      raw = raw.map { |value| [ value ] } if @selection.one?
      rows = raw.map { |row| decode(row) }
      raise Compiler::Refused.new(:too_many_groups) if @refuse_when_cut && truncated?(rows)

      Result.new(columns: @columns, rows: rows.first(@limit || rows.size), truncated: truncated?(rows))
    end

    private

    # Aliased so that pluck reads what the database returned. Otherwise it casts a column through the root model's attribute
    # of the same name, which is wrong as soon as a joined table has a column named like one of the root's.
    def aliased_selection
      @selection.each_with_index.map { |node, index| node.as("c#{index}") }
    end

    # One row more than asked: it is how a result knows it was cut.
    def limited
      @limit ? @relation.limit(@limit + 1) : @relation
    end

    def truncated?(rows)
      !@limit.nil? && rows.size > @limit
    end

    def decode(row)
      row.each_with_index.map { |value, index| @decoders[index] ? @decoders[index].call(value) : value }
    end
  end
end
