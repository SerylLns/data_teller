require "data_teller/providers/openai/strict_schema"

module DataTeller
  module Providers
    # OpenAI's Responses API with a strict JSON schema (ADR 0008 D2). Raw HTTP through LLM::HTTP.
    #
    #   c.llm = DataTeller::Providers::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"), model: "...")
    #
    # options: extra request fields for a given model (reasoning effort, max_output_tokens...). They cannot override what the
    # adapter sets: the model, the prompt, the schema, and store: false.
    class OpenAI
      ENDPOINT = "https://api.openai.com/v1/responses".freeze
      # OpenAI echoes part of a wrong key in its 401 message: even masked, a key does not go to the log.
      KEY_PATTERN = /sk-[A-Za-z0-9_*\-]+/
      SCHEMA_NAME = "data_teller".freeze

      attr_reader :model

      def initialize(api_key:, model:, http: LLM::HTTP.new, options: {})
        raise ConfigurationError, "OpenAI needs an api_key" unless api_key.is_a?(String) && api_key.present?
        raise ConfigurationError, "OpenAI needs a model name" unless model.is_a?(String) && model.present?

        @api_key = api_key.dup.freeze
        @model = model.dup.freeze
        @http = http
        @options = options.deep_stringify_keys.freeze
      end

      def complete(system:, user:, schema:)
        translated = provider_schema(schema)
        StrictSchema.check!(translated)

        data, latency = @http.post_json(ENDPOINT, headers: { "Authorization" => "Bearer #{@api_key}" }, body: body(system, user, translated),
                                                  redact: method(:redact))
        LLM::Response.new(
          output: StrictSchema.unwrap(output_of(data), schema),
          input_tokens: data.dig("usage", "input_tokens"),
          output_tokens: data.dig("usage", "output_tokens"),
          latency_ms: latency
        )
      end

      def provider_schema(schema)
        StrictSchema.call(schema)
      end

      # The key stays out of consoles, error pages and logs that print the configuration.
      def inspect
        "#<#{self.class.name} model=#{@model.inspect}>"
      end
      alias_method :to_s, :inspect

      private

      def body(system, user, schema)
        @options.merge(
          "model" => @model,
          "instructions" => system,
          "input" => user,
          # Not kept for later retrieval: the question is the end user's, and nothing reads a response back.
          "store" => false,
          "text" => { "format" => { "type" => "json_schema", "name" => SCHEMA_NAME, "strict" => true, "schema" => schema } }
        )
      end

      # Reasoning models put reasoning items before the message, so the message is looked for, not taken first.
      # A refusal's text is not kept: it may quote the question.
      def output_of(data)
        raise LLM::ProviderError, "OpenAI failed: #{redact(data.dig('error', 'message').to_s.truncate(300))}" if data["error"]
        if data["status"] == "incomplete"
          raise LLM::IncompleteResponse, "OpenAI stopped before the end (#{data.dig('incomplete_details', 'reason') || 'no reason given'})"
        end

        content = Array(Array(data["output"]).find { |item| item["type"] == "message" }&.dig("content"))
        raise LLM::Refused, "the model declined to answer" if content.any? { |part| part["type"] == "refusal" }

        text = content.find { |part| part["type"] == "output_text" }&.dig("text")
        raise LLM::InvalidResponse, "OpenAI sent no output text" unless text

        JSON.parse(text)
      rescue JSON::ParserError
        raise LLM::InvalidResponse, "OpenAI's output is not JSON"
      end

      def redact(text)
        text.gsub(@api_key, "[redacted]").gsub(KEY_PATTERN, "sk-[redacted]")
      end
    end
  end
end
