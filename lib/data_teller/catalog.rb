module DataTeller
  # What a set of roles can see. The one choke point of ADR 0004 D5: schema generation uses it today, and retrieval,
  # suggestions, explanations and the validator will too, so that the whole chain agrees on what exists.
  # It holds only declared names, and is computed from roles, never from a user.
  class Catalog
    Entry = Data.define(:name, :model_name, :dataset, :metrics, :fields, :segments)

    # A dimension as a query can name it: its own (status) or through a path (customer.city).
    # steps: the associations to join. via: the datasets of those joined tables, each needing its own tenant filter.
    Field = Data.define(:name, :model_name, :dimension, :steps, :via) do
      def model = model_name.constantize

      # Reads the column type, so this needs the database or the schema cache. Never called at boot.
      def kind
        return dimension.type if dimension.type

        klass = model
        return :enum if klass.defined_enums.key?(dimension.column)

        case klass.type_for_attribute(dimension.column).type
        when :date, :datetime, :timestamp, :timestamptz then :date
        when :boolean then :boolean
        when :integer, :bigint, :decimal, :float then :number
        else :string
        end
      end

      def date? = kind == :date

      # An enum's values come from the model, never from the DSL (ADR 0004 D3). nil for a type forced with `type: :enum`.
      def enum_values = model.defined_enums[dimension.column]&.keys

      # The bind casts through the column type, so 1000.5 would silently be compared as 1000.
      def integer? = %i[integer bigint].include?(model.type_for_attribute(dimension.column).type)

      def high_cardinality? = !%i[enum boolean date].include?(kind)

      # Time goes through period, never through filters (ADR 0001 D1).
      def filterable? = dimension.filter && !date?
      def period? = dimension.filter && date?

      # Grouping by a high-cardinality column lists rows in disguise, so it takes an explicit opt-in (ADR 0004 D3).
      def groupable?
        dimension.group.nil? ? !high_cardinality? : dimension.group
      end
    end

    attr_reader :roles, :datasets

    def self.for(*roles)
      new(roles.flatten)
    end

    # The way in for a request. Recomputed each time: a role change takes effect on the next question (ADR 0004 D5).
    def self.for_user(user)
      new(DataTeller.config.roles_for(user))
    end

    def initialize(roles, registry: DataTeller.registry, tenant_model_name: DataTeller.config.tenant_model_name)
      @roles = Array(roles).map(&:to_sym).uniq
      @registry = registry
      @tenant_model_name = tenant_model_name
      @datasets = registry.datasets.select { |dataset| visible?(dataset) }.map { |dataset| entry_for(dataset) }.freeze
    end

    def dataset(name)
      datasets.find { |entry| entry.name == name.to_sym }
    end

    def dataset_for_model(model_name)
      @registry.datasets.find { |dataset| dataset.model_name == model_name }
    end

    private

    def visible?(dataset)
      (Array(dataset.roles) & @roles).any?
    end

    # Members inherit the dataset's roles when they declare none.
    def member_visible?(member, dataset)
      ((member.roles || dataset.roles) & @roles).any?
    end

    def entry_for(dataset)
      Entry.new(
        name: dataset.name,
        model_name: dataset.model_name,
        dataset: dataset,
        metrics: dataset.metrics.values.select { |metric| metric_visible?(metric, dataset) }.freeze,
        fields: (own_fields(dataset) + path_fields(dataset)).freeze,
        segments: dataset.segments.values.select { |segment| segment_visible?(segment, dataset) }.freeze
      )
    end

    # A ratio is visible only if everything it divides is: count + avg_basket would otherwise reveal revenue.
    def metric_visible?(metric, dataset)
      return false unless member_visible?(metric, dataset) && metric_path_visible?(metric, dataset) && metric_column_visible?(metric, dataset)

      metric.dependencies.all? do |dependency|
        declared = dataset.metrics[dependency]
        declared && metric_visible?(declared, dataset)
      end
    end

    # A metric over another table shows data of that table, so its dataset must be visible too.
    def metric_path_visible?(metric, dataset)
      return true if metric.steps.empty?

      visible_along_path = true
      ModelLookup.follow_metric_path(dataset.model_name.constantize, metric.steps) do |reflection|
        target = @registry.datasets.find { |candidate| candidate.model_name == reflection.class_name }
        visible_along_path &&= target && visible?(target)
      end
      visible_along_path
    rescue ModelLookup::PathError
      false
    end

    # max: :total_cents reads the column, so a permission on that column applies to the metric (ADR 0004 D5).
    def metric_column_visible?(metric, dataset)
      return true unless metric.column

      owner, column = ModelLookup.column_owner(dataset.model_name.constantize, metric.column)
      return false unless owner

      owner_dataset = owner.name == dataset.model_name ? dataset : dataset_for_model(owner.name)
      return true unless owner_dataset

      owner_dataset.dimensions.values.none? { |dimension| dimension.column == column && !member_visible?(dimension, owner_dataset) }
    end

    # A segment on a hidden column would reveal its values by bisection (ADR 0004 D5).
    def segment_visible?(segment, dataset)
      return false unless member_visible?(segment, dataset)
      return true if segment.scope?

      hidden = dataset.dimensions.values.reject { |dimension| member_visible?(dimension, dataset) }
      segment.where.keys.none? { |key| hidden.any? { |dimension| dimension.column == key.to_s || dimension.name == key } }
    end

    def own_fields(dataset)
      dataset.dimensions.values.select { |dimension| member_visible?(dimension, dataset) }.map do |dimension|
        Field.new(name: dimension.name, model_name: dataset.model_name, dimension: dimension, steps: [], via: [])
      end
    end

    # A path inherits the permissions of its target, not only those of the starting dataset (ADR 0001 D4).
    def path_fields(dataset)
      hops = DimensionPaths.hops(dataset, registry: @registry, tenant_model_name: @tenant_model_name)

      hops.select { |hop| hop.via.all? { |step| visible?(step) } }.flat_map do |hop|
        hop.target.dimensions.values.select { |dimension| member_visible?(dimension, hop.target) }.map do |dimension|
          Field.new(name: :"#{hop.prefix}.#{dimension.name}", model_name: hop.target.model_name, dimension: dimension,
                    steps: hop.steps, via: hop.via)
        end
      end
    end
  end
end
