require "json"
require "json_schemer"

module DataTeller
  # Structural validation only (ADR 0001). Whether names are declared, whether a
  # dimension may be filtered, and permissions are checked by the validator against the registry.
  module QuerySchema
    PATH = File.expand_path("schema/query_v1.json", __dir__)

    # ECMA is the regexp dialect of JSON Schema. With the default Ruby dialect `^` and `$` match at every line,
    # so "orders\nDROP TABLE orders" would satisfy an anchored pattern.
    def self.schemer
      @schemer ||= JSONSchemer.schema(Pathname.new(PATH), regexp_resolver: "ecma")
    end

    def self.valid?(query)
      schemer.valid?(query)
    end

    def self.definition
      @definition ||= JSON.parse(File.read(PATH)).freeze
    end

    # Returns the JSON pointers and error types, which the eval can aggregate.
    def self.errors(query)
      schemer.validate(query).map { |e| { pointer: e["data_pointer"], type: e["type"] } }
    end
  end
end
