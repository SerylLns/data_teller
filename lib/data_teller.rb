require "data_teller/version"
require "data_teller/errors"
require "data_teller/configuration"
require "data_teller/name_format"
require "data_teller/metric"
require "data_teller/dimension"
require "data_teller/segment"
require "data_teller/always"
require "data_teller/list_declaration"
require "data_teller/min_group_size"
require "data_teller/dataset"
require "data_teller/dataset_builder"
require "data_teller/registry"
require "data_teller/loader"
require "data_teller/model_lookup"
require "data_teller/model_validator"
require "data_teller/schema_validator"
require "data_teller/dimension_paths"
require "data_teller/catalog"
require "data_teller/schema_generator"
require "data_teller/catalog_summary"
require "data_teller/prompt"
require "data_teller/query_validator"
require "data_teller/period_resolver"
require "data_teller/condition_whitelist"
require "data_teller/scope_inspector"
require "data_teller/tenant_scope"
require "data_teller/plan"
require "data_teller/compared_plan"
require "data_teller/read_only_execution"
require "data_teller/query_cost"
require "data_teller/compiler"
require "data_teller/hidden_names"
require "data_teller/reader_grants"
require "data_teller/row_policies"
require "data_teller/role_validator"
require "data_teller/row_security_validator"
require "data_teller/query_runner"
require "data_teller/isolation_check"
require "data_teller/isolation_check/command"
require "data_teller/cost_report"
require "data_teller/cost_report/command"
require "data_teller/llm"
require "data_teller/providers/openai"
require "data_teller/router"
require "data_teller/pipeline"
require "data_teller/ask"
require "data_teller/palette_helper"
require "data_teller/evaluation/question_set"
require "data_teller/evaluation/normalizer"
require "data_teller/evaluation/scorer"
require "data_teller/evaluation/executor"
require "data_teller/evaluation/models"
require "data_teller/evaluation/runner"
require "data_teller/evaluation/report"
require "data_teller/evaluation/command"
require "data_teller/validator"
require "data_teller/engine"
require "data_teller/query_schema"

module DataTeller
  class << self
    # What is published here has been validated. Until a boot succeeds these are an empty configuration, so no tenant
    # and no role, and an empty frozen registry, so nothing is exposed.
    def config
      @config ||= Configuration.new.freeze
    end

    def registry
      @registry ||= Registry.new.freeze!
    end

    # Only valid inside config/data_teller.rb. From an initializer the settings would be lost at the next load:
    # refusing is better than a resolver that silently disappears.
    def configure
      context = Loader.current
      unless context
        raise ConfigurationError, "DataTeller.configure belongs in #{Loader::GLOBAL_FILE}, which is loaded by the engine"
      end

      yield context.config
      context.config
    end

    # Declares what is exposed for one model. Takes the class or its name, so a declaration file does not need the
    # model to be loaded first. Only valid inside config/data_teller/*.rb, for the same reason as configure.
    def refine(model, name: nil, &block)
      context = Loader.current
      unless context
        raise DeclarationError, "DataTeller.refine #{model.inspect} belongs in #{File.dirname(Loader::DATASET_FILES)}/, which is loaded by the engine"
      end
      raise DeclarationError, "refine #{model.inspect} needs a block" unless block

      builder = DatasetBuilder.new(model.respond_to?(:name) ? model.name : model.to_s, name: name)
      builder.instance_eval(&block)
      context.registry.register(builder.build)
    end

    # Loads and validates the files without touching the running engine: it is safe from a console or a health check.
    # schema: true adds what needs the database, so the boot must leave it off (ADR 0004 D6).
    def check(root, schema: false)
      loaded = Loader.call(root)
      Validator.new(
        config: loaded.config, registry: loaded.registry,
        load_errors: loaded.errors, skipped_checks: loaded.skipped_checks, schema: schema
      ).call
    end

    # The engine is closed first and opened last, so every way out of this method other than success leaves it closed.
    # on_invalid_config comes from the file being loaded: if that file breaks before setting it, the default :raise
    # applies, which is the loud and safe side (ADR 0004 D6).
    def boot!(root)
      close!
      return if @boot_deferred

      unless Loader.configured?(root)
        Rails.logger&.warn("[DataTeller] not configured, the engine is off. Run `rails generate data_teller:install`.")
        return
      end

      report = check(root)
      return open!(report) if report.ok?

      raise ConfigurationError, report.message if report.config.on_invalid_config == :raise

      Rails.logger&.error("[DataTeller] DISABLED, configuration is invalid and on_invalid_config is :disable. #{report.message}")
      nil
    end

    # For `rake data_teller:check`, which must get to report the problems itself instead of dying during the boot.
    # The engine stays closed, so this cannot expose anything.
    def defer_boot!
      @boot_deferred = true
    end

    def enabled?
      @enabled == true
    end

    # A question and a user in, an outcome out (ADR 0010 D1): rows, a clarification or a refusal, for any visual.
    def ask(question, user:, now: Time.current)
      Ask.call(question, user: user, now: now)
    end

    # For tests only.
    def reset!
      close!
      @boot_deferred = false
    end

    private

    def close!
      @enabled = false
      @config = nil
      @registry = nil
    end

    def open!(report)
      @config = report.config.freeze
      @registry = report.registry.freeze!
      @enabled = true
    end
  end
end
