require "rails_helper"
require "yaml"

RSpec.describe DataTeller::Providers::OpenAI::StrictSchema do
  roles = %i[admin support member]

  def keywords(node, found = Set.new)
    case node
    when Hash
      node.each do |key, value|
        found << key
        %w[properties $defs].include?(key) ? value.each_value { |item| keywords(item, found) } : keywords(value, found)
      end
    when Array then node.each { |item| keywords(item, found) }
    end
    found
  end

  def objects(node, found = [])
    case node
    when Hash
      found << node if node["properties"]
      node.each { |key, value| %w[properties $defs].include?(key) ? value.each_value { |item| objects(item, found) } : objects(value, found) }
    when Array then node.each { |item| objects(item, found) }
    end
    found
  end

  # What a strict model must write for a query: every optional property present as null, inside the wrapper.
  def pad(value, node, defs)
    node = defs.fetch(node["$ref"].delete_prefix("#/$defs/")) if node["$ref"]
    if node["anyOf"]
      node["anyOf"].each do |member|
        candidate = pad(value, member, defs)
        return candidate if JSONSchemer.schema(member.merge("$defs" => defs)).valid?(candidate)
      end
      return value
    end
    if value.is_a?(Hash) && node["properties"] && (value.keys - node["properties"].keys).empty?
      return node["properties"].to_h { |name, schema| [ name, value.key?(name) ? pad(value[name], schema, defs) : nil ] }
    end
    return value.map { |item| pad(item, node["items"], defs) } if value.is_a?(Array) && node["items"]

    value
  end

  roles.each do |role|
    describe "the #{role} schema" do
      let(:original) { DataTeller::SchemaGenerator.for_roles(role) }
      let(:translated) { described_class.call(original) }

      it "keeps only what strict mode takes, with an object at the root" do
        expect(translated).to include("type" => "object", "required" => [ "query" ], "additionalProperties" => false)
        expect(translated.keys).not_to include("anyOf", "oneOf")
        expect(keywords(translated) & %w[oneOf allOf not if then else dependentRequired dependentSchemas uniqueItems $schema]).to be_empty
      end

      it "gives every schema a type, a reference or a union" do
        untyped = []
        find = lambda do |node, named|
          case node
          when Hash
            next node.each_value { |item| find.(item, false) } if named

            untyped << node unless node.key?("type") || node.key?("$ref") || node.key?("anyOf")
            node.except("enum", "const", "required").each { |key, value| find.(value, %w[properties $defs].include?(key)) }
          when Array then node.each { |item| find.(item, false) }
          end
        end
        find.(translated, false)

        expect(untyped).to eq([])
      end

      it "closes every object and requires every property" do
        expect(objects(translated)).to all(satisfy { |object|
          object["additionalProperties"] == false && object["required"] == object["properties"].keys
        })
      end

      it "stays within the documented limits" do
        counts = described_class.check!(translated)

        expect(counts[:nesting]).to be <= described_class::MAX_NESTING
        expect(counts[:enum_values]).to be <= described_class::MAX_ENUM_VALUES
      end
    end
  end

  # A translation that forbids a right answer would score the model wrong (ADR 0008 D1).
  it "still accepts every expected query of the working set, and gives it back unchanged" do
    questions = YAML.safe_load_file(Rails.root.join("eval/dev.yml"))["questions"]
    by_role = roles.index_with { |role| [ (schema = DataTeller::SchemaGenerator.for_roles(role)), described_class.call(schema) ] }

    aggregate_failures do
      questions.each do |question|
        original, translated = by_role.fetch(question.fetch("role", "admin").to_sym)
        schemer = JSONSchemer.schema(translated)

        [ question["expected"], *question["also_accepted"] ].each do |query|
          written = { "query" => pad(query, translated["properties"]["query"], translated["$defs"]) }

          expect(schemer.valid?(written)).to be(true), "#{question['id']}: refused by the translated schema"
          expect(described_class.unwrap(written, original)).to eq(query), "#{question['id']}: changed by unwrap"
        end
      end
    end
  end

  # The translation's safety rests on this: what strict mode cannot say, the validator still refuses.
  it "drops only rules the validator still applies" do
    validator = DataTeller::QueryValidator.new(DataTeller::Catalog.for(:admin))
    base = { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "revenue" }
    broken = {
      "uniqueItems" => { "version" => 1, "intent" => "clarify", "clarify" => { "options" => %w[revenue revenue] } },
      "dependentRequired" => base.merge("compare" => "previous_period"),
      "if/then" => base.merge("filters" => [ { "dimension" => "status", "op" => "is_null", "value" => "paid" } ]),
      "allOf + not" => base.merge("order_by" => { "by" => "metric", "dir" => "desc", "dimension" => "status" })
    }

    broken.each do |rule, query|
      expect(validator.call(query).problems).to include(a_hash_including(code: :invalid_structure)), rule
    end
  end

  it "keeps a property whose name is a dropped keyword" do
    schema = { "type" => "object", "properties" => { "if" => { "type" => "string" }, "not" => { "type" => "number" } }, "required" => [ "if" ] }

    expect(described_class.call(schema)).to eq(
      "type" => "object",
      "properties" => { "if" => { "type" => "string" }, "not" => { "anyOf" => [ { "type" => "number" }, { "type" => "null" } ] } },
      "required" => %w[if not],
      "additionalProperties" => false
    )
  end

  it "types a const or an enum by its values" do
    schema = {
      "type" => "object",
      "properties" => { "version" => { "const" => 1 }, "unit" => { "enum" => %w[day week] }, "mixed" => { "enum" => [ "a", 1.5, true ] } },
      "required" => %w[version unit mixed]
    }

    expect(described_class.call(schema)["properties"]).to eq(
      "version" => { "const" => 1, "type" => "integer" },
      "unit" => { "enum" => %w[day week], "type" => "string" },
      "mixed" => { "enum" => [ "a", 1.5, true ], "type" => %w[string number boolean] }
    )
  end

  it "leaves an object root unwrapped" do
    schema = { "type" => "object", "properties" => { "datasets" => { "type" => "array", "items" => { "enum" => %w[orders] } } }, "required" => [ "datasets" ] }

    expect(described_class.call(schema)["properties"].keys).to eq([ "datasets" ])
    expect(described_class.unwrap({ "datasets" => [ "orders" ] }, schema)).to eq("datasets" => [ "orders" ])
  end

  it "refuses an answer that is not an object" do
    expect { described_class.unwrap({ "query" => "orders" }, { "anyOf" => [] }) }.to raise_error(DataTeller::LLM::InvalidResponse)
  end

  it "says which limit a schema is over, and what to do" do
    schema = { "type" => "object", "properties" => { "name" => { "enum" => (1..1_001).map { |n| "name_#{n}" } } }, "required" => [ "name" ] }

    expect { described_class.check!(described_class.call(schema)) }
      .to raise_error(DataTeller::LLM::SchemaTooLarge, /1001 enum values \(at most 1000\).*Send fewer datasets \(ADR 0007\)/)
  end

  it "counts a definition once, however often it is referenced, but follows it for nesting" do
    inner = { "type" => "object", "properties" => { "unit" => { "enum" => %w[day week] } }, "required" => [ "unit" ] }
    schema = {
      "type" => "object",
      "properties" => { "a" => { "$ref" => "#/$defs/inner" }, "b" => { "$ref" => "#/$defs/inner" } },
      "required" => %w[a b],
      "$defs" => { "inner" => inner }
    }

    expect(described_class.check!(described_class.call(schema))).to include(enum_values: 2, nesting: 2, properties: 3)
  end
end
