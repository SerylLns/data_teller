module DataTeller
  # Boot validation, part A: checks that need only the declarations and the config, never the database
  # (ADR 0004 D6). It reports every problem at once. It does not prove the tenant path or that columns exist;
  # that is part B, which reads the ActiveRecord schema.
  class Validator
    # A lint, not a guarantee: a list of words cannot recognise every sensitive column, which is why nothing is
    # exposed unless it is declared. Identifiers are compared word by word, so that `monkey` does not trip `key`.
    SENSITIVE_WORDS = %w[
      email mail phone telephone mobile password passwd pwd passphrase token secret credential
      iban ssn salt digest otp cvv cvc passport birthdate birthday dob address encrypted ciphertext
    ].freeze
    SENSITIVE_PHRASES = %w[
      api_key access_key private_key encryption_key credit_card card_number e_mail
      date_of_birth social_security tax_id national_id
    ].freeze

    Report = Data.define(:errors, :warnings, :config, :registry) do
      def ok?
        errors.empty?
      end

      def message
        "DataTeller configuration is invalid (#{errors.size} #{errors.size == 1 ? 'error' : 'errors'}):\n" +
          errors.map { |error| "  - #{error}" }.join("\n")
      end
    end

    # load_errors and skipped_checks come from the Loader: its problems are reported along with ours, minus the checks
    # that would only repeat them.
    def initialize(config:, registry:, load_errors: [], skipped_checks: [])
      @config = config
      @registry = registry
      @load_errors = load_errors
      @skipped_checks = skipped_checks
    end

    def call
      @errors = @load_errors.dup
      @warnings = []

      check_tenant unless @skipped_checks.include?(:tenant)
      check_exposure unless @skipped_checks.include?(:exposure)
      @registry.datasets.each { |dataset| check_dataset(dataset) }

      Report.new(errors: @errors.freeze, warnings: @warnings.freeze, config: @config, registry: @registry)
    end

    private

    # The tenant is what keeps one customer's data from another's: no tenant, no engine.
    def check_tenant
      unless @config.tenant_declared?
        @errors << "no tenant: declare it in config/data_teller.rb with `c.tenant do model Account; resolve { |user| user.account } end`"
        return
      end

      @errors << "tenant: `model` is missing, e.g. `model Account`" unless @config.tenant_model_name
      @errors << "tenant: `resolve` is missing, e.g. `resolve { |user| user.account }`" unless @config.tenant_resolver
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
      check_metric_columns(dataset)
      check_role_narrowing(dataset)
    end

    def check_time_dimensions(dataset)
      times = dataset.dimensions.values.select(&:time).map(&:name)
      return if times.size <= 1

      @errors << "dataset #{dataset.name}: only one default time dimension is allowed, got #{times.join(', ')}"
    end

    def check_dimensions(dataset)
      dataset.dimensions.each_value do |dimension|
        check_sensitive("dataset #{dataset.name}, dimension #{dimension.name}", "dimension", dimension,
                        dimension.name, dimension.column)
      end
    end

    # min and max return a stored value, so a metric over a column can read that column.
    def check_metric_columns(dataset)
      dataset.metrics.each_value do |metric|
        check_sensitive("dataset #{dataset.name}, metric #{metric.name}", "metric", metric, metric.column)
      end
    end

    def check_sensitive(at, kind, member, *identifiers)
      if !member.sensitive && sensitive_identifier?(*identifiers)
        @errors << "#{at}: the name looks sensitive; expose it only with `sensitive: true` and explicit `roles:`"
      end
      @errors << "#{at}: a sensitive #{kind} needs explicit `roles:`" if member.sensitive && member.roles.nil?
    end

    def check_segments(dataset)
      dataset.segments.each_value do |segment|
        at = "dataset #{dataset.name}, segment #{segment.name}"
        check_scope_segment(at, segment) if segment.scope?

        if segment.where && segment.roles.nil? && sensitive_identifier?(*segment.where.keys)
          @errors << "#{at}: a condition on a sensitive-looking column needs explicit `roles:`"
        end
      end
    end

    # A scope is arbitrary code that cannot be analysed, so its audience cannot be inferred (ADR 0004 D5).
    # A method every model has (destroy_all, unscoped, all) is not a scope the developer wrote for this purpose.
    def check_scope_segment(at, segment)
      @errors << "#{at}: a `scope:` segment needs explicit `roles:`" if segment.roles.nil?
      return unless ActiveRecord::Base.respond_to?(segment.scope)

      @errors << "#{at}: `scope: :#{segment.scope}` is a built-in ActiveRecord method, not a scope of the model"
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

    def sensitive_identifier?(*identifiers)
      identifiers.compact.any? do |identifier|
        words = identifier.to_s.underscore.split(/[_.]+/).map(&:singularize)
        joined = "_#{words.join('_')}_"

        (words & SENSITIVE_WORDS).any? || SENSITIVE_PHRASES.any? { |phrase| joined.include?("_#{phrase}_") }
      end
    end
  end
end
