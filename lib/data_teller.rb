require "data_teller/version"
require "data_teller/errors"
require "data_teller/configuration"
require "data_teller/name_format"
require "data_teller/metric"
require "data_teller/dimension"
require "data_teller/segment"
require "data_teller/dataset"
require "data_teller/registry"
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

    # For tests and development reloads only.
    def reset!
      @config = nil
      @registry = nil
    end
  end
end
