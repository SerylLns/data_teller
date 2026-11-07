require "data_teller/ui_configuration"
require "data_teller/tenant_declaration"

module DataTeller
  # Global settings (config/data_teller.rb). Datasets are declared separately with DataTeller.refine (ADR 0004 D1).
  class Configuration
    ON_INVALID_CONFIG = %i[raise disable].freeze

    MIN_STATEMENT_TIMEOUT = 0.001

    LIMITS = {
      # Seconds. Postgres reads 0 as "no timeout", which is why zero is refused below.
      statement_timeout: 5,
      # Applies to a high-cardinality group_by whose dimension has no max_groups (ADR 0004 D3).
      default_max_groups: 50,
      max_rows: 1_000,
      # Beyond this a date series is refused, not cut: a top N of days means nothing.
      max_time_points: 366,
      # Tables joined for one query (ADR 0001 D4).
      max_joins: 5
    }.freeze

    attr_reader :on_invalid_config, :ui, :roles_resolver, *LIMITS.keys
    attr_accessor :llm

    def initialize
      @on_invalid_config = :raise
      @ui = UiConfiguration.new
      @exposed_models = []
      @tenant = nil
      @roles_resolver = nil
      @llm = nil
      @authorization = nil
      LIMITS.each { |name, value| instance_variable_set(:"@#{name}", value) }
    end

    # A typo here must never mean "no limit".
    def statement_timeout=(value)
      # Below a millisecond it would round to 0, which Postgres reads as no timeout.
      unless value.is_a?(Numeric) && value.real? && value.finite? && value >= MIN_STATEMENT_TIMEOUT
        raise ConfigurationError, "statement_timeout must be a number of seconds, of at least #{MIN_STATEMENT_TIMEOUT}, got #{value.inspect}"
      end

      @statement_timeout = value
    end

    LIMITS.keys.without(:statement_timeout).each do |name|
      define_method(:"#{name}=") do |value|
        minimum = name == :max_joins ? 0 : 1
        unless value.is_a?(Integer) && value >= minimum
          raise ConfigurationError, "#{name} must be an Integer of at least #{minimum}, got #{value.inspect}"
        end

        instance_variable_set(:"@#{name}", value)
      end
    end

    # The published configuration holds the tenant resolver: nothing may swap it once it has been validated.
    def freeze
      @ui.freeze
      @exposed_models.freeze
      @tenant&.freeze
      super
    end

    # Both modes fail closed (ADR 0004 D6); the choice is about the host app's availability.
    def on_invalid_config=(value)
      unless ON_INVALID_CONFIG.include?(value)
        raise ConfigurationError, "on_invalid_config must be one of #{ON_INVALID_CONFIG.inspect}, got #{value.inspect}"
      end

      @on_invalid_config = value
    end

    # Required, with its two lines (ADR 0004 D7); boot validation refuses to start without them.
    #   c.tenant do
    #     model Account
    #     resolve { |user| user.account }
    #   end
    def tenant(&block)
      raise ConfigurationError, "tenant needs a block: c.tenant do model Account; resolve { |user| user.account } end" unless block

      @tenant = TenantDeclaration.new.tap { |declaration| declaration.instance_eval(&block) }
    end

    def tenant_declared?
      !@tenant.nil?
    end

    def tenant_model_name
      @tenant&.model_name
    end

    def tenant_resolver
      @tenant&.resolver
    end

    # c.roles { |user| user.roles } — resolved on every request, never cached per user (ADR 0004 D5).
    def roles(&block)
      raise ConfigurationError, "roles needs a block: c.roles { |user| user.roles }" unless block

      @roles_resolver = block
    end

    # c.authorization :pundit — the adapter itself is validated by the authorization ticket (T33).
    def authorization(adapter = nil)
      @authorization = adapter unless adapter.nil?
      @authorization
    end

    # Models are kept by name so that code reloading in development never leaves stale classes in the config.
    def expose(*models)
      @exposed_models |= models.flatten.map { |model| model.respond_to?(:name) ? model.name : model.to_s }
    end

    def exposed_models
      @exposed_models.dup.freeze
    end

    # Fails closed: nil means no tenant, which the compiler turns into a refusal. A resolver returning some other record
    # would otherwise scope every query to the wrong thing. Only the class is logged, a message could hold user data.
    def tenant_for(user)
      return nil unless tenant_resolver && tenant_model_name

      tenant = tenant_resolver.call(user)
      return tenant if tenant.is_a?(tenant_model_name.constantize)

      Rails.logger&.error("[DataTeller] tenant resolver returned #{tenant.class}, expected #{tenant_model_name}") unless tenant.nil?
      nil
    rescue StandardError => e
      Rails.logger&.error("[DataTeller] tenant resolver failed, treating as no tenant: #{e.class}")
      nil
    end

    # nil when the tenant's zone is wrong or unknown: the caller refuses, because the wrong "today" is a wrong answer.
    def time_zone_for(tenant)
      resolver = @tenant&.time_zone_resolver
      return Time.zone || ActiveSupport::TimeZone["UTC"] unless resolver

      name = resolver.call(tenant)
      ActiveSupport::TimeZone[name.to_s].tap do |zone|
        Rails.logger&.error("[DataTeller] unknown tenant time zone, refusing the query") unless zone
      end
    rescue StandardError => e
      Rails.logger&.error("[DataTeller] tenant time zone failed, refusing the query: #{e.class}")
      nil
    end

    # Fails closed: no resolver, nil, or an error all mean "no role", which means no access.
    def roles_for(user)
      return [] unless @roles_resolver

      Array(@roles_resolver.call(user)).compact.map(&:to_sym).uniq
    rescue StandardError => e
      Rails.logger&.error("[DataTeller] roles resolver failed, treating as no role: #{e.class}")
      []
    end
  end
end
