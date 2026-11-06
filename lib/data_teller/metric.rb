module DataTeller
  # A metric never contains free code (ADR 0004 D2): a closed set of aggregations, plus ratio of two other metrics.
  class Metric < Data.define(:name, :aggregation, :column, :of, :format, :roles)
    AGGREGATIONS = %i[count sum avg min max count_distinct ratio].freeze
    COLUMN_AGGREGATIONS = %i[sum avg min max count_distinct].freeze

    def initialize(name:, aggregation:, column: nil, of: nil, format: nil, roles: nil)
      unless AGGREGATIONS.include?(aggregation)
        raise DeclarationError, "metric #{name.inspect}: aggregation must be one of #{AGGREGATIONS.inspect}, got #{aggregation.inspect}"
      end

      super(
        name: NameFormat.ensure!(name, "metric"),
        aggregation: aggregation,
        column: column_for(name, aggregation, column),
        of: ratio_for(name, aggregation, of),
        format: format&.to_sym,
        roles: NameFormat.roles(roles, "metric")
      )
    end

    def ratio?
      aggregation == :ratio
    end

    # Metrics this one depends on; the derived metric is visible only if all of them are (ADR 0004 D5).
    def dependencies
      ratio? ? of : [].freeze
    end

    private

    def column_for(name, aggregation, column)
      if COLUMN_AGGREGATIONS.include?(aggregation)
        raise DeclarationError, "metric #{name.inspect}: #{aggregation} needs a column" if column.nil?

        column.to_sym
      else
        raise DeclarationError, "metric #{name.inspect}: #{aggregation} does not take a column" unless column.nil?

        nil
      end
    end

    def ratio_for(name, aggregation, of)
      if aggregation == :ratio
        unless of.is_a?(Array) && of.size == 2
          raise DeclarationError, "metric #{name.inspect}: ratio needs exactly two metrics, e.g. ratio: [:revenue, :count]"
        end

        of.map { |metric| NameFormat.ensure!(metric, "ratio metric") }.freeze
      else
        raise DeclarationError, "metric #{name.inspect}: only ratio takes metrics to divide" unless of.nil?

        nil
      end
    end
  end
end
