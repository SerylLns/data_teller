module DataTeller
  # What the gem expects from a provider (ADR 0008 D1). An adapter answers two methods:
  #
  #   complete(system:, user:, schema:)  # => DataTeller::LLM::Response, or raises a DataTeller::LLM::Error
  #   provider_schema(schema)            # DataTeller's JSON schema -> the subset this provider accepts; pure
  #
  # The gem owns the prompts and the chain of calls; the adapter owns HTTP, authentication, the schema translation and reading the answer.
  module LLM
    # output: the query as a Hash, in DataTeller's own shape (whatever the adapter had to wrap or pad is undone).
    Response = Data.define(:output, :input_tokens, :output_tokens, :latency_ms)

    def self.adapter?(object)
      object.respond_to?(:complete) && object.respond_to?(:provider_schema)
    end

    # Messages are for the developer's log: they name the provider and the status, never the key, the prompt or the question.
    class Error < DataTeller::Error; end

    # The connection could not be made, after the retries.
    class ConnectionError < Error; end

    # The provider took longer than the read timeout. Not retried: the user is already waiting.
    class TimeoutError < Error; end

    # Still rate limited after the retries, or asked to wait longer than a request should.
    class RateLimited < Error; end

    # Any other answer than a success: a refused key, a schema the provider rejects, a server error after the retries.
    class ProviderError < Error
      attr_reader :status

      def initialize(message, status: nil)
        @status = status
        super(message)
      end
    end

    # The model stopped before the end, usually on its output token limit.
    class IncompleteResponse < Error; end

    # The model declined to answer (a provider's safety refusal, not DataTeller's out_of_scope).
    class Refused < Error; end

    # The answer could not be read: no output, or output that is not JSON.
    class InvalidResponse < Error; end

    # The schema is over one of the provider's documented limits: raised before sending, since the call would fail anyway.
    # Narrowing the catalog is the way out (ADR 0007).
    class SchemaTooLarge < Error; end
  end
end

require "data_teller/llm/http"
