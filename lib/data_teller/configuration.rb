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
      max_joins: 5,
      # Up to this many datasets a role's whole catalog goes in the prompt; beyond it a router narrows it first (ADR 0007 D6).
      # An estimate from OpenAI's documented limits, not measured on a large catalog: lower it if a role gets LLM::SchemaTooLarge.
      route_above_datasets: 12
    }.freeze

    # A plain Postgres name: it is quoted in the SQL anyway, and this keeps a typo from becoming a role nobody created.
    DATABASE_ROLE = /\A[a-z_][a-z0-9_]{0,62}\z/

    attr_reader :on_invalid_config, :ui, :roles_resolver, :database_role, :row_security, :llm, *LIMITS.keys

    def initialize
      @on_invalid_config = :raise
      @ui = UiConfiguration.new
      @exposed_models = []
      @tenant = nil
      @roles_resolver = nil
      @current_user_resolver = nil
      @llm = nil
      @router_llm = nil
      @authorization = nil
      @database_role = nil
      @row_security = false
      LIMITS.each { |name, value| instance_variable_set(:"@#{name}", value) }
    end

    # The Postgres role each query runs as (T37, ADR 0005 D6). nil, the default, keeps the app's own database user.
    def database_role=(value)
      unless value.nil? || (value.is_a?(String) && DATABASE_ROLE.match?(value))
        raise ConfigurationError, "database_role must be a lowercase Postgres role name such as \"data_teller_reader\", or nil, got #{value.inspect}"
      end

      @database_role = value&.dup&.freeze
    end

    # The provider adapter (ADR 0008 D1): anything answering complete and provider_schema, so an integrator can write their own.
    def llm=(adapter)
      @llm = checked_adapter(:llm, adapter)
    end

    # The router's call (ADR 0007 D1) may use a smaller, cheaper model; the same adapter as llm unless set.
    def router_llm=(adapter)
      @router_llm = checked_adapter(:router_llm, adapter)
    end

    def router_llm
      @router_llm || @llm
    end

    # Postgres row-level security on top of the compiler's tenant filter (T39, ADR 0005 D7). Needs database_role, which the
    # policies apply to: the boot refuses one without the other.
    def row_security=(value)
      raise ConfigurationError, "row_security must be true or false, got #{value.inspect}" unless [ true, false ].include?(value)

      @row_security = value
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
        # 0 is a real setting for these two: no join allowed, the router on every question.
        minimum = %i[max_joins route_above_datasets].include?(name) ? 0 : 1
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

    # c.current_user { |request| request.env["warden"]&.user } — who is asking, for the endpoint and the helper (ADR 0010 D2).
    def current_user(&block)
      raise ConfigurationError, "current_user needs a block: c.current_user { |request| ... }" unless block

      @current_user_resolver = block
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

    # Fails closed: no resolver, nil or an error all mean nobody, which the endpoint answers with a 401.
    def current_user_for(request)
      @current_user_resolver&.call(request)
    rescue StandardError => e
      Rails.logger&.error("[DataTeller] current_user failed, treating as nobody: #{e.class}")
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

    private

    def checked_adapter(name, adapter)
      return adapter if adapter.nil? || LLM.adapter?(adapter)

      raise ConfigurationError, "#{name} must answer complete(system:, user:, schema:) and provider_schema(schema), got #{adapter.class}"
    end
  end
end
