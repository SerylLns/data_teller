module DataTeller
  module Providers
    class OpenAI
      # DataTeller's schema in the subset OpenAI's strict mode takes, as documented on 2026-11-08 (ADR 0007, context):
      # - no allOf, not, if/then/else, dependentRequired or uniqueItems: dropped, the validator checks every output against the
      #   whole schema anyway (QuerySchema.valid?). uniqueItems was found by the first real call, not in the documentation;
      # - oneOf becomes anyOf: our unions are disjoint, so nothing more is accepted;
      # - the root must be an object, not a union: a union root is wrapped in {"query": ...}, and unwrapped from the answer;
      # - every property is required: an optional one becomes "this or null", and the nulls are removed from the answer;
      # - every schema has a type, found by the first real call and not in the documentation: a const or an enum gets the type
      #   of its values.
      # A lost rule makes an output that the validator refuses, never a wider query: the schema is not a security boundary.
      module StrictSchema
        DROPPED = %w[$schema allOf not if then else dependentRequired dependentSchemas uniqueItems].freeze
        # Maps whose keys are names, not keywords: a property may well be called "if".
        NAMED_SCHEMAS = %w[properties $defs].freeze
        WRAPPER = "query".freeze

        # The documented limits of a strict schema.
        MAX_PROPERTIES = 5_000
        MAX_NESTING = 10
        MAX_ENUM_VALUES = 1_000
        MAX_STRING_LENGTH = 120_000
        LONG_ENUM = 250
        MAX_LONG_ENUM_LENGTH = 15_000

        module_function

        def call(schema)
          return translate(schema) unless union_root?(schema)

          root = {
            "type" => "object",
            "properties" => { WRAPPER => translate("anyOf" => union_of(schema)) },
            "required" => [ WRAPPER ],
            "additionalProperties" => false
          }
          root["$defs"] = translate_named(schema["$defs"]) if schema["$defs"]
          root
        end

        # The answer back in DataTeller's shape. Our queries hold no null value anywhere, so every null is a padded optional.
        def unwrap(output, schema)
          output = output[WRAPPER] if union_root?(schema) && output.is_a?(Hash)
          raise LLM::InvalidResponse, "the answer is not a JSON object" unless output.is_a?(Hash)

          without_nulls(output)
        end

        # Raised before sending: OpenAI would refuse the request with a 400 anyway, and this message says what to do.
        def check!(translated)
          counts = measure(translated)
          problems = []
          problems << "#{counts[:properties]} properties (at most #{MAX_PROPERTIES})" if counts[:properties] > MAX_PROPERTIES
          problems << "#{counts[:nesting]} levels of nesting (at most #{MAX_NESTING})" if counts[:nesting] > MAX_NESTING
          problems << "#{counts[:enum_values]} enum values (at most #{MAX_ENUM_VALUES})" if counts[:enum_values] > MAX_ENUM_VALUES
          problems << "#{counts[:string_length]} characters of names and values (at most #{MAX_STRING_LENGTH})" if counts[:string_length] > MAX_STRING_LENGTH
          problems << "an enum of more than #{LONG_ENUM} values over #{MAX_LONG_ENUM_LENGTH} characters" if counts[:long_enum]
          return counts if problems.empty?

          raise LLM::SchemaTooLarge, "the schema is over OpenAI's strict mode limits: #{problems.join(', ')}. Send fewer datasets (ADR 0007)."
        end

        # Each definition is counted once, however often it is referenced: the documentation does not say otherwise, and
        # counting every use would refuse schemas OpenAI takes. Nesting does follow references, since that is what the model fills.
        def measure(schema)
          counts = { properties: 0, nesting: nesting(schema, schema.fetch("$defs", {}), 0, []), enum_values: 0, string_length: 0, long_enum: false }
          counts[:string_length] += schema.fetch("$defs", {}).keys.sum(&:length)
          count(schema, counts)
          counts
        end

        def union_root?(schema)
          schema.key?("anyOf") || schema.key?("oneOf")
        end

        def union_of(schema)
          Array(schema["anyOf"]) + Array(schema["oneOf"])
        end

        def translate(node)
          case node
          when Array then node.map { |item| translate(item) }
          when Hash then close_object(typed(translate_keywords(node)))
          else node
          end
        end

        def translate_keywords(node)
          node = node.except(*DROPPED)
          node = node.except("oneOf").merge("anyOf" => union_of(node)) if node.key?("oneOf")
          node.to_h { |key, value| [ key, NAMED_SCHEMAS.include?(key) ? translate_named(value) : translate(value) ] }
        end

        def translate_named(map)
          map.transform_values { |schema| translate(schema) }
        end

        def typed(node)
          return node if node.key?("type") || !(node.key?("const") || node.key?("enum"))

          types = (node.key?("const") ? [ node["const"] ] : node["enum"]).map { |value| json_type(value) }.uniq
          node.merge("type" => types.one? ? types.first : types)
        end

        def json_type(value)
          case value
          when String then "string"
          when Integer then "integer"
          when Float then "number"
          when true, false then "boolean"
          when nil then "null"
          else raise ArgumentError, "a const or enum value must be a scalar, got #{value.class}"
          end
        end

        def close_object(node)
          return node unless node["properties"]

          required = Array(node["required"])
          properties = node["properties"].to_h { |name, schema| [ name, required.include?(name) ? schema : nullable(schema) ] }
          node.merge("properties" => properties, "required" => properties.keys, "additionalProperties" => false)
        end

        def nullable(schema)
          { "anyOf" => [ schema, { "type" => "null" } ] }
        end

        def without_nulls(value)
          case value
          when Hash then value.reject { |_, item| item.nil? }.transform_values { |item| without_nulls(item) }
          when Array then value.map { |item| without_nulls(item) }
          else value
          end
        end

        # Objects inside objects; a definition is followed once per path, so a recursive one cannot loop.
        def nesting(node, defs, depth, seen)
          case node
          when Array then node.map { |item| nesting(item, defs, depth, seen) }.max || depth
          when Hash
            name = node["$ref"]&.delete_prefix("#/$defs/")
            via_ref = defs.key?(name) && !seen.include?(name) ? nesting(defs[name], defs, depth, seen + [ name ]) : depth
            depth += 1 if node["properties"]
            children = node.except("enum", "const", "required", "$defs").map do |key, value|
              nesting(key == "properties" ? value.values : value, defs, depth, seen)
            end
            [ depth, via_ref, *children ].max
          else depth
          end
        end

        def count(node, counts)
          case node
          when Array then node.each { |item| count(item, counts) }
          when Hash
            count_names(node, counts)
            node.except("enum", "const", "required").each do |key, value|
              count(%w[properties $defs].include?(key) ? value.values : value, counts)
            end
          end
        end

        def count_names(node, counts)
          if node["properties"]
            counts[:properties] += node["properties"].size
            counts[:string_length] += node["properties"].keys.sum(&:length)
          end
          if node["enum"]
            values = node["enum"].map(&:to_s)
            counts[:enum_values] += values.size
            counts[:string_length] += values.sum(&:length)
            counts[:long_enum] ||= values.size > LONG_ENUM && values.sum(&:length) > MAX_LONG_ENUM_LENGTH
          end
          counts[:string_length] += node["const"].to_s.length if node.key?("const")
        end
      end
    end
  end
end
