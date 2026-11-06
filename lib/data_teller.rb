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

    # Development reloads: declarations are rebuilt, global settings are kept.
    def registry_reset!
      @registry = nil
    end

    # For tests only.
    def reset!
      @config = nil
      @registry = nil
    end
  end
end
