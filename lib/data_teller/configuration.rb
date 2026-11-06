require "data_teller/ui_configuration"

module DataTeller
  # Global settings (config/data_teller.rb). Datasets are declared separately with DataTeller.refine (ADR 0004 D1).
  class Configuration
    ON_INVALID_CONFIG = %i[raise disable].freeze

    attr_reader :on_invalid_config, :ui, :tenant_resolver, :roles_resolver
    attr_accessor :llm

    def initialize
      @on_invalid_config = :raise
      @ui = UiConfiguration.new
      @exposed_models = []
      @tenant_resolver = nil
      @roles_resolver = nil
      @llm = nil
      @authorization = nil
    end

    # The published configuration holds the tenant resolver: nothing may swap it once it has been validated.
    def freeze
      @ui.freeze
      @exposed_models.freeze
      super
    end

    # Both modes fail closed (ADR 0004 D6); the choice is about the host app's availability.
    def on_invalid_config=(value)
      unless ON_INVALID_CONFIG.include?(value)
        raise ConfigurationError, "on_invalid_config must be one of #{ON_INVALID_CONFIG.inspect}, got #{value.inspect}"
      end

      @on_invalid_config = value
    end

    # c.tenant { |user| user.account } — required; boot validation (T07) refuses to start without it.
    def tenant(&block)
      raise ConfigurationError, "tenant needs a block: c.tenant { |user| user.account }" unless block

      @tenant_resolver = block
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

    def tenant_for(user)
      @tenant_resolver&.call(user)
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
