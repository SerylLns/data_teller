module DataTeller
  # Checks the declarations against the real tables. It reads the database, so it only runs in
  # `rake data_teller:check`, never at boot: a boot that did this could not run the migration adding a column (ADR 0004 D6).
  class SchemaValidator
    NUMBER_TYPES = %i[integer bigint decimal float].freeze
    DATE_TYPES = %i[date datetime timestamp timestamptz].freeze
    TEXT_TYPES = %i[string text citext].freeze
    FORBIDDEN_IN_SCOPE = { order: :order_values, limit: :limit_value, group: :group_values, select: :select_values }.freeze

    def initialize(registry:)
      @registry = registry
    end

    def call
      @errors = []

      @registry.datasets.each do |dataset|
        klass = ModelLookup.active_record_class(dataset.model_name)
        next unless klass # ModelValidator reports it

        if klass.table_exists?
          check_dataset(dataset, klass)
        else
          @errors << "dataset #{dataset.name}: table #{klass.table_name} does not exist"
        end
      end

      @errors
    rescue ActiveRecord::ActiveRecordError => e
      # Only the class: the message of a connection error names hosts and users, and this output goes to CI logs.
      [ "cannot read the database to check the columns: #{e.class}" ]
    end

    private

    def check_dataset(dataset, klass)
      dataset.dimensions.each_value { |dimension| check_dimension(dataset, klass, dimension) }
      dataset.metrics.each_value { |metric| check_metric(dataset, klass, metric) }
      dataset.segments.each_value { |segment| check_segment(dataset, klass, segment) }
    end

    def check_dimension(dataset, klass, dimension)
      at = "dataset #{dataset.name}, dimension #{dimension.name}"
      column = column_of(at, klass, dimension.column)
      return unless column

      if dimension.time && !DATE_TYPES.include?(column.type)
        @errors << "#{at}: `time: true` needs a date or datetime column, #{column.name} is #{column.type}"
      end
      return unless dimension.lookup && !TEXT_TYPES.include?(column.type)

      @errors << "#{at}: `lookup:` needs a text column, #{column.name} is #{column.type}"
    end

    def check_metric(dataset, klass, metric)
      return unless metric.column

      at = "dataset #{dataset.name}, metric #{metric.name}"
      owner, name = ModelLookup.column_owner(klass, metric.column)
      return unless owner # ModelValidator reports it

      column = column_of(at, owner, name)
      check_aggregation(at, metric, column) if column
    end

    # On a text column, min and max return a stored value: row-level disclosure presented as an aggregate.
    def check_aggregation(at, metric, column)
      case metric.aggregation
      when :sum, :avg
        @errors << "#{at}: #{metric.aggregation} needs a number, #{column.name} is #{column.type}" unless NUMBER_TYPES.include?(column.type)
      when :min, :max
        return if NUMBER_TYPES.include?(column.type) || DATE_TYPES.include?(column.type)

        @errors << "#{at}: #{metric.aggregation} returns a stored value, it needs a number or a date, #{column.name} is #{column.type}"
      end
    end

    def check_segment(dataset, klass, segment)
      at = "dataset #{dataset.name}, segment #{segment.name}"

      if segment.scope?
        check_scope(at, klass, segment.scope) if ModelLookup.declared_scope?(klass, segment.scope)
      else
        # A nested hash such as { days_ago: 30 } is a declarative condition, interpreted by the compiler.
        segment.where.each { |key, value| column_of(at, klass, key.to_s) unless value.is_a?(Hash) }
      end
    end

    # Calling a scope is the only way to inspect it, and only names registered by `scope` get this far, so a class method
    # is never called. The rollback is there because a scope is still code: it should not write, but this must not find out
    # the hard way on a CI or staging database.
    def check_scope(at, klass, name)
      klass.transaction(requires_new: true) do
        inspect_scope(at, name, klass.public_send(name))
        raise ActiveRecord::Rollback
      end
    rescue ArgumentError
      @errors << "#{at}: scope :#{name} takes an argument, a segment has none to give it"
    end

    def inspect_scope(at, name, relation)
      unless relation.is_a?(ActiveRecord::Relation)
        @errors << "#{at}: scope :#{name} does not return a relation"
        return
      end

      FORBIDDEN_IN_SCOPE.each do |clause, reader|
        @errors << "#{at}: scope :#{name} uses #{clause}, which would change the result of an aggregate" if relation.public_send(reader).present?
      end
    end

    def column_of(at, klass, name)
      unless klass.table_exists?
        @errors << "#{at}: table #{klass.table_name} does not exist"
        return nil
      end

      klass.columns_hash[name.to_s].tap do |column|
        @errors << "#{at}: #{klass.name} has no column #{name}" unless column
      end
    end
  end
end
