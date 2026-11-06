module DataTeller
  # Boot validation against the models: what can be checked by reading their code, without a database connection
  # (ADR 0004 D6). Columns and their types need the database and are checked by SchemaValidator.
  class ModelValidator
    def initialize(config:, registry:, check_exposure: true)
      @config = config
      @registry = registry
      @check_exposure = check_exposure
    end

    def call
      @errors = []
      @tenant_model = tenant_model

      @registry.datasets.each do |dataset|
        klass = ModelLookup.active_record_class(dataset.model_name)
        if klass
          check_dataset(dataset, klass)
        else
          @errors << "dataset #{dataset.name}: model #{dataset.model_name} is not an ActiveRecord model"
        end
      end

      @errors
    end

    private

    def tenant_model
      name = @config.tenant_model_name
      return nil unless name

      ModelLookup.active_record_class(name).tap do |klass|
        @errors << "tenant: model #{name} is not an ActiveRecord model" unless klass
      end
    end

    def check_dataset(dataset, klass)
      check_tenant_path(dataset, klass)
      check_metric_paths(dataset, klass)
      check_scopes(dataset, klass)
      check_paths_are_distinct(dataset)
    end

    # The LLM could not tell customer.city from billing_customer.city (ADR 0001 D4).
    def check_paths_are_distinct(dataset)
      hops = DimensionPaths.hops(dataset, registry: @registry, tenant_model_name: @config.tenant_model_name)

      hops.group_by(&:target).each do |target, same_target|
        next if same_target.size < 2

        @errors << "dataset #{dataset.name}: #{same_target.map(&:prefix).join(' and ')} both lead to #{target.model_name}, " \
                   "so their dimensions would be ambiguous"
      end
    end

    def check_tenant_path(dataset, klass)
      at = "dataset #{dataset.name}"
      return unless @tenant_model

      if klass <= @tenant_model
        @errors << "#{at}: this is the tenant model, it has no tenant_path (the filter is its own id)" if dataset.tenant_path
      elsif dataset.tenant_path.nil?
        @errors << "#{at}: tenant_path is required, e.g. `tenant_path :#{@tenant_model.model_name.singular}`"
      else
        check_path_to_tenant(at, dataset, klass)
      end
    end

    def check_path_to_tenant(at, dataset, klass)
      reached = ModelLookup.follow(klass, dataset.tenant_path) do |current, step, reflection|
        unless reflection.belongs_to?
          raise ModelLookup::PathError, "#{current.name}.#{step} is a #{reflection.macro}, only belongs_to identifies one tenant"
        end
      end
      return if reached <= @tenant_model

      @errors << "#{at}: tenant_path ends at #{reached.name}, not at #{@tenant_model.name}"
    rescue ModelLookup::PathError => e
      @errors << "#{at}: tenant_path: #{e.message}"
    end

    # Every table touched needs its own tenant_path, so a path can only go through exposed models (ADR 0001 D4).
    def check_metric_paths(dataset, klass)
      dataset.metrics.each_value do |metric|
        steps = metric.column.to_s.split(".")[0...-1]
        at = "dataset #{dataset.name}, metric #{metric.name}"
        check_ratio_has_no_path(at, dataset, metric)
        next if steps.empty?

        ModelLookup.follow(klass, steps) { |_current, _step, reflection| check_exposed(at, reflection) }
      rescue ModelLookup::PathError => e
        @errors << "#{at}: #{e.message}"
      end
    end

    # The join a path needs would change what the other side of the ratio counts (ADR 0005 D2).
    def check_ratio_has_no_path(at, dataset, metric)
      metric.dependencies.each do |dependency|
        next unless dataset.metrics[dependency]&.column.to_s.include?(".")

        @errors << "#{at}: a ratio cannot use #{dependency}, a metric through a path"
      end
    end

    def check_exposed(at, reflection)
      return unless @check_exposure
      return if @config.exposed_models.include?(reflection.class_name)

      @errors << "#{at}: the path reaches #{reflection.class_name}, which is not exposed"
    end

    # Built-in methods are reported by Validator, which has a clearer message for them.
    def check_scopes(dataset, klass)
      dataset.segments.each_value do |segment|
        next if !segment.scope? || ActiveRecord::Base.respond_to?(segment.scope)
        next if ModelLookup.declared_scope?(klass, segment.scope)

        @errors << "dataset #{dataset.name}, segment #{segment.name}: #{klass.name} has no scope :#{segment.scope} " \
                   "(declared with `scope`; a class method could do anything when called)"
      end
    end
  end
end
