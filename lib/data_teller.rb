require "data_teller/version"
require "data_teller/errors"
require "data_teller/configuration"
require "data_teller/engine"
require "data_teller/query_schema"

module DataTeller
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    # For tests and development reloads only.
    def reset!
      @config = nil
    end
  end
end
