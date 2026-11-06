module DataTeller
  # The `c.tenant do ... end` block (ADR 0004 D7). `model` is what every tenant_path must reach, which the boot has to
  # know since `resolve` only runs on a request.
  class TenantDeclaration
    attr_reader :model_name, :resolver

    # Kept by name, like the exposed models, so that code reloading never leaves a stale class in the config.
    def model(value)
      @model_name = value.respond_to?(:name) ? value.name : value.to_s
    end

    def resolve(&block)
      raise ConfigurationError, "tenant: resolve needs a block: resolve { |user| user.account }" unless block

      @resolver = block
    end
  end
end
