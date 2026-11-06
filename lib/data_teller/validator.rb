module DataTeller
  # Boot validation, part A: checks that need only the declarations and the config, never the database
  # (ADR 0004 D6). It reports every problem at once. It does not prove the tenant path or that columns exist;
  # that is part B, which reads the ActiveRecord schema.
  class Validator
    # Words that make a dimension look like personal data or a secret. A name is matched word by word so that
    # `monkey` does not trip `key`.
    SENSITIVE_WORDS = %w[email phone mobile password passwd token secret iban ssn salt digest].freeze

    Report = Data.define(:errors, :warnings) do
      def ok?
        errors.empty?
      end

      def message
        "DataTeller configuration is invalid (#{errors.size} #{errors.size == 1 ? 'error' : 'errors'}):\n" +
          errors.map { |error| "  - #{error}" }.join("\n")
      end
    end

    def initialize(config: DataTeller.config, registry: DataTeller.registry)
      @config = config
      @registry = registry
    end

    def call
      @errors = []
      @warnings = []

      check_tenant
      check_exposure
      @registry.datasets.each { |dataset| check_dataset(dataset) }

      Report.new(errors: @errors.freeze, warnings: @warnings.freeze)
    end

    private

    # The tenant is what keeps one customer's data from another's: no tenant, no engine.
    def check_tenant
      return if @config.tenant_resolver

      @errors << "no tenant resolver: set `c.tenant { |user| user.account }` in config/data_teller.rb"
    end

    # Exposure must be visible in two places that agree: the `expose` list and a `refine` per model.
    def check_exposure
      declared = @registry.datasets.map(&:model_name)
      exposed = @config.exposed_models

      (exposed - declared).each { |model| @errors << "#{model} is exposed but has no `DataTeller.refine #{model}` block" }
      (declared - exposed).each { |model| @errors << "#{model} is refined but not listed in `c.expose`" }
    end

    def check_dataset(dataset)
      at = dataset.name
      @errors << "dataset #{at}: roles are required (`roles :admin, ...`), nothing is visible by default" if dataset.roles.nil?

      check_time_dimensions(dataset)
      check_dimensions(dataset)
      check_segments(dataset)
      check_metrics(dataset)
      check_role_narrowing(dataset)
    end

    def check_time_dimensions(dataset)
      times = dataset.dimensions.values.select(&:time).map(&:name)
      return if times.size <= 1

      @errors << "dataset #{dataset.name}: only one default time dimension is allowed, got #{times.join(', ')}"
    end

    def check_dimensions(dataset)
      dataset.dimensions.each_value do |dimension|
        at = "dataset #{dataset.name}, dimension #{dimension.name}"
        looks_sensitive = sensitive_name?(dimension)

        if looks_sensitive && !dimension.sensitive
          @errors << "#{at}: the name looks sensitive; expose it only with `sensitive: true` and explicit `roles:`"
        end
        if dimension.sensitive && dimension.roles.nil?
          @errors << "#{at}: a sensitive dimension needs explicit `roles:`"
        end
      end
    end

    # A scope is arbitrary code that cannot be analysed, so its audience cannot be inferred (ADR 0004 D5).
    def check_segments(dataset)
      dataset.segments.each_value do |segment|
        next unless segment.scope? && segment.roles.nil?

        @errors << "dataset #{dataset.name}, segment #{segment.name}: a `scope:` segment needs explicit `roles:`"
      end
    end

    def check_metrics(dataset)
      dataset.metrics.each_value do |metric|
        metric.dependencies.each do |dependency|
          next if dataset.metrics.key?(dependency)

          @errors << "dataset #{dataset.name}, metric #{metric.name}: ratio refers to unknown metric #{dependency}"
        end
      end

      cycle = metric_cycle(dataset)
      @errors << "dataset #{dataset.name}: derived metrics form a cycle (#{cycle.join(' -> ')})" if cycle
    end

    # Depth-first walk; returns the path of the first cycle found, or nil.
    def metric_cycle(dataset)
      done = []
      dataset.metrics.each_key do |name|
        cycle = find_cycle(dataset, name, [], done)
        return cycle if cycle
      end
      nil
    end

    def find_cycle(dataset, name, path, done)
      return nil if done.include?(name) || !dataset.metrics.key?(name)
      return path.drop_while { |step| step != name } + [ name ] if path.include?(name)

      dataset.metrics[name].dependencies.each do |dependency|
        cycle = find_cycle(dataset, dependency, path + [ name ], done)
        return cycle if cycle
      end
      done << name
      nil
    end

    # Members can only narrow the dataset's roles, never widen them (ADR 0004 D5). Otherwise a metric declared for
    # `billing` inside an `admin` dataset would be an access nobody reviewed at the dataset level.
    def check_role_narrowing(dataset)
      return if dataset.roles.nil?

      { metric: dataset.metrics, dimension: dataset.dimensions, segment: dataset.segments }.each do |kind, members|
        members.each_value do |member|
          extra = (member.roles || []) - dataset.roles
          next if extra.empty?

          @errors << "dataset #{dataset.name}, #{kind} #{member.name}: roles #{extra.inspect} are not in the dataset's roles " \
                     "#{dataset.roles.inspect} (members can only narrow)"
        end
      end
    end

    def sensitive_name?(dimension)
      words = "#{dimension.name}_#{dimension.column}".split(/[_.]/)
      (words & SENSITIVE_WORDS).any?
    end
  end
end
