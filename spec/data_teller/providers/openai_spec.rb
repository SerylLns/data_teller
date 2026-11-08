require "rails_helper"

RSpec.describe DataTeller::Providers::OpenAI do
  let(:key) { "sk-proj-test0123456789" }
  let(:requests) { [] }
  let(:schema) { DataTeller::SchemaGenerator.for_roles(:member) }
  let(:query) { { "version" => 1, "intent" => "answer", "dataset" => "orders", "metric" => "order_count" } }

  # A response as the Responses API sends it: reasoning first, then the message.
  def answer(text, status: "completed", usage: { "input_tokens" => 1200, "output_tokens" => 40 }, content: nil)
    {
      "status" => status,
      "error" => nil,
      "output" => [
        { "type" => "reasoning", "summary" => [] },
        { "type" => "message", "role" => "assistant", "content" => content || [ { "type" => "output_text", "text" => text } ] }
      ],
      "usage" => usage
    }
  end

  def padded(query) = JSON.generate("query" => query.merge("period" => nil, "filters" => nil, "group_by" => nil, "order_by" => nil, "limit" => nil, "compare" => nil))

  def adapter(*bodies, status: 200, **options)
    transport = lambda do |uri, headers, body|
      requests << { uri: uri, headers: headers, body: JSON.parse(body) }
      DataTeller::LLM::HTTP::Reply.new(status: status, body: JSON.generate(bodies.shift), retry_after: nil)
    end
    described_class.new(api_key: key, model: "some-model", http: DataTeller::LLM::HTTP.new(transport: transport, sleeper: ->(_) { }), **options)
  end

  def complete(llm) = llm.complete(system: "the prompt", user: "how many orders?", schema: schema)

  it "sends the prompt with the translated schema in strict mode, and nothing kept by OpenAI" do
    complete(adapter(answer(padded(query))))

    request = requests.first
    expect(request[:uri].to_s).to eq("https://api.openai.com/v1/responses")
    expect(request[:headers]).to include("Authorization" => "Bearer #{key}")
    expect(request[:body]).to include("model" => "some-model", "instructions" => "the prompt", "input" => "how many orders?", "store" => false)
    expect(request[:body]["text"]["format"]).to eq(
      "type" => "json_schema", "name" => "data_teller", "strict" => true, "schema" => DataTeller::Providers::OpenAI::StrictSchema.call(schema)
    )
  end

  it "gives back the query in DataTeller's shape, with the tokens and the latency" do
    response = complete(adapter(answer(padded(query))))

    expect(response.output).to eq(query)
    expect(response).to have_attributes(input_tokens: 1200, output_tokens: 40)
    expect(response.latency_ms).to be_a(Integer)
  end

  it "adds a model's options without letting them replace what the adapter sets" do
    llm = adapter(answer(padded(query)), options: { reasoning: { effort: "low" }, store: true, model: "other", text: {} })
    complete(llm)

    expect(requests.first[:body]).to include("reasoning" => { "effort" => "low" }, "store" => false, "model" => "some-model")
    expect(requests.first[:body]["text"]["format"]["strict"]).to be(true)
  end

  it "says when the model declined, without its words" do
    refusal = answer(nil, content: [ { "type" => "refusal", "refusal" => "I cannot help with how many orders?" } ])

    expect { complete(adapter(refusal)) }.to raise_error(DataTeller::LLM::Refused, "the model declined to answer")
  end

  it "says when the model stopped before the end" do
    expect { complete(adapter(answer("{\"query\":", status: "incomplete").merge("incomplete_details" => { "reason" => "max_output_tokens" }))) }
      .to raise_error(DataTeller::LLM::IncompleteResponse, /max_output_tokens/)
  end

  it "refuses an answer it cannot read" do
    expect { complete(adapter(answer("not json"))) }.to raise_error(DataTeller::LLM::InvalidResponse)
    expect { complete(adapter(answer(nil, content: []))) }.to raise_error(DataTeller::LLM::InvalidResponse)
    expect { complete(adapter(answer(JSON.generate("query" => "orders")))) }.to raise_error(DataTeller::LLM::InvalidResponse)
  end

  it "keeps the key out of an error, even the part OpenAI echoes back" do
    error = { "error" => { "message" => "Incorrect API key provided: sk-proj-****6789. Also #{key}." } }

    expect { complete(adapter(error, status: 401)) }.to raise_error(DataTeller::LLM::ProviderError) { |raised|
      expect(raised.status).to eq(401)
      expect(raised.message).to eq("the provider answered 401: Incorrect API key provided: sk-[redacted]. Also [redacted].")
    }
  end

  it "keeps the key out of inspect" do
    llm = adapter

    expect(llm.inspect).to eq('#<DataTeller::Providers::OpenAI model="some-model">')
    expect(llm.to_s).not_to include(key)
    expect(DataTeller::Configuration.new.tap { |config| config.llm = llm }.inspect).not_to include(key)
  end

  it "does not call OpenAI with a schema over its limits" do
    too_large = { "type" => "object", "properties" => { "name" => { "enum" => (1..1_001).map(&:to_s) } }, "required" => [ "name" ] }

    expect { adapter.complete(system: "s", user: "u", schema: too_large) }.to raise_error(DataTeller::LLM::SchemaTooLarge)
    expect(requests).to be_empty
  end

  it "needs a key and a model" do
    expect { described_class.new(api_key: nil, model: "m") }.to raise_error(DataTeller::ConfigurationError, /api_key/)
    expect { described_class.new(api_key: "", model: "m") }.to raise_error(DataTeller::ConfigurationError, /api_key/)
    expect { described_class.new(api_key: key, model: " ") }.to raise_error(DataTeller::ConfigurationError, /model/)
  end
end
