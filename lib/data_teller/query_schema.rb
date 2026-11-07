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
      finite?(query) && schemer.valid?(query)
    end

    def self.definition
      @definition ||= JSON.parse(File.read(PATH)).freeze
    end

    # Returns the JSON pointers and error types, which the eval can aggregate.
    def self.errors(query)
      return [ { pointer: "", type: "not_finite" } ] unless finite?(query)

      schemer.validate(query).map { |e| { pointer: e["data_pointer"], type: e["type"] } }
    end

    # JSON.parse reads 1e400 as Infinity, which is a number to the schema, and raises in the schemer on an integer field.
    # Before anything else, so that an LLM's output cannot turn into an exception.
    def self.finite?(value)
      case value
      when Numeric then value.finite?
      when Hash then value.values.all? { |item| finite?(item) }
      when Array then value.all? { |item| finite?(item) }
      else true
      end
    end
  end
end
