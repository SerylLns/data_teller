module DataTeller
  # The JSON schema sent to the LLM for a set of roles: query_v1.json with its free names replaced by what the catalog
  # shows, one branch per dataset (ADR 0004 D8). Not a security boundary: the validator re-checks everything (T22).
  # Reads column types, so it runs on a request or in a rake task, never at boot.
  class SchemaGenerator
    KEPT_DEFINITIONS = %w[iso_date range scalar].freeze

    def self.for_roles(*roles)
      new(Catalog.for(*roles)).call
    end

    def initialize(catalog)
      @catalog = catalog
      @base = QuerySchema.definition
      @defs = @base["$defs"]
    end

    def call
      branches = @catalog.datasets.select { |entry| entry.metrics.any? }.map { |entry| answer_branch(entry) }
      clarify = clarify_branch

      {
        "$schema" => @base["$schema"],
        "title" => "DataTeller query for the current role",
        "type" => "object",
        "required" => @base["required"],
        "anyOf" => [ *branches, *clarify, @defs["out_of_scope"].deep_dup ],
        "$defs" => @defs.slice(*KEPT_DEFINITIONS).deep_dup
      }
    end

    private

    # additionalProperties is false, so removing a property makes it impossible to write.
    def answer_branch(entry)
      branch = @defs["answer"].deep_dup
      properties = branch["properties"]

      properties["dataset"] = { "const" => entry.name.to_s }
      properties["metric"] = enum(entry.metrics.map(&:name))
      restrict_period(branch, entry)
      restrict_filters(properties, entry)
      restrict_grouping(properties, entry)
      branch
    end

    def restrict_period(branch, entry)
      names = entry.fields.select(&:period?).map(&:name)
      properties = branch["properties"]

      if names.empty?
        properties.delete("period")
        properties.delete("compare")
        branch.delete("dependentRequired")
      else
        properties["period"] = @defs["period"].deep_dup
        properties["period"]["properties"]["dimension"] = enum(names)
      end
    end

    def restrict_filters(properties, entry)
      kinds = [ *segment_filter(entry), *comparison_filter(entry) ]

      if kinds.empty?
        properties.delete("filters")
      else
        properties["filters"]["items"] = { "anyOf" => kinds }
      end
    end

    def segment_filter(entry)
      return [] if entry.segments.empty?

      filter = @defs["filter"]["oneOf"].first.deep_dup
      filter["properties"]["segment"] = enum(entry.segments.map(&:name))
      [ filter ]
    end

    def comparison_filter(entry)
      names = entry.fields.select(&:filterable?).map(&:name)
      return [] if names.empty?

      comparison = @defs["comparison"].deep_dup
      comparison["properties"]["dimension"] = enum(names)
      [ comparison ]
    end

    def restrict_grouping(properties, entry)
      names = entry.fields.select(&:groupable?).map(&:name)
      order_by = @defs["order_by"].deep_dup

      if names.empty?
        properties.delete("group_by")
        order_by["properties"]["by"] = enum(%w[metric])
        order_by["properties"].delete("dimension")
        order_by.delete("allOf")
      else
        item = @defs["group_by_item"].deep_dup
        item["properties"]["dimension"] = enum(names)
        properties["group_by"]["items"] = item
        order_by["properties"]["dimension"] = enum(names)
      end
      properties["order_by"] = order_by
    end

    # Options are visible names only: asking "did you mean revenue?" would reveal a forbidden metric.
    # Two options are the minimum of the format, so with fewer names there is nothing to ask.
    def clarify_branch
      names = @catalog.datasets.flat_map do |entry|
        [ entry.name, *entry.metrics.map(&:name), *entry.fields.map(&:name), *entry.segments.map(&:name) ]
      end.uniq
      return [] if names.size < 2

      branch = @defs["clarify"].deep_dup
      branch["properties"]["clarify"]["properties"]["options"]["items"] = enum(names)
      [ branch ]
    end

    def enum(names)
      { "enum" => names.map(&:to_s) }
    end
  end
end
