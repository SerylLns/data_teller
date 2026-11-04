require "json"
require "json_schemer"

module DataTeller
  # Structural validation only (ADR 0001). Whether names are declared, whether a
  # dimension may be filtered, and permissions are checked by the validator against the registry.
  module QuerySchema
    PATH = File.expand_path("schema/query_v1.json", __dir__)

    def self.schemer
      @schemer ||= JSONSchemer.schema(Pathname.new(PATH))
    end

    def self.valid?(query)
      schemer.valid?(query)
    end

    # Returns the JSON pointers and error types, which the eval can aggregate.
    def self.errors(query)
      schemer.validate(query).map { |e| { pointer: e["data_pointer"], type: e["type"] } }
    end
  end
end
