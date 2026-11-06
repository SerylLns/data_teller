require "data_teller/version"
require "data_teller/errors"
require "data_teller/configuration"
require "data_teller/name_format"
require "data_teller/metric"
require "data_teller/dimension"
require "data_teller/segment"
require "data_teller/dataset"
require "data_teller/dataset_builder"
require "data_teller/registry"
require "data_teller/loader"
require "data_teller/validator"
require "data_teller/engine"
require "data_teller/query_schema"

module DataTeller
  class << self
    def config
      @config ||= Configuration.new
    end

    def registry
      @registry ||= Registry.new
    end

    def configure
      yield config
      config
    end

    # Declares what is exposed for one model. Takes the class or its name, so a declaration file does not need the
    # model to be loaded first.
    def refine(model, name: nil, &block)
      raise DeclarationError, "refine #{model.inspect} needs a block" unless block

      builder = DatasetBuilder.new(model.respond_to?(:name) ? model.name : model.to_s, name: name)
      builder.instance_eval(&block)
      registry.register(builder.build)
    end

    # Loads, validates and, only if everything is valid, freezes the declarations and enables the engine.
    # Both failure modes leave the engine disabled (fail closed); the setting decides whether the host app also
    # refuses to boot (ADR 0004 D6). A broken declaration file is treated like any other invalid configuration.
    def boot!(root)
      problems = begin
        Loader.load!(root)
        Validator.new.call.errors
      rescue Error => e
        [ e.message ]
      end

      @enabled = problems.empty?
      return registry.freeze! if @enabled

      message = Validator::Report.new(errors: problems, warnings: []).message
      raise ConfigurationError, message if config.on_invalid_config == :raise

      Rails.logger&.error("[DataTeller] DISABLED, configuration is invalid and on_invalid_config is :disable. #{message}")
      nil
    end

    # False until a boot validated the configuration, so that nothing is served by default.
    def enabled?
      @enabled == true
    end

    # Development reloads: declarations are rebuilt, global settings are kept.
    def registry_reset!
      @registry = nil
    end

    # For tests only.
    def reset!
      @config = nil
      @registry = nil
      @enabled = false
    end
  end
end
