require "json"
require "net/http"
require "uri"

module DataTeller
  module LLM
    # The HTTP shared by the shipped adapters (ADR 0008 D1): JSON in and out, timeouts, a few retries, the latency of the whole call.
    # Net::HTTP from the standard library, so no dependency. The transport is injectable: specs never touch the network.
    class HTTP
      # What a transport returns. retry_after is the header as sent, nil when absent.
      Reply = Data.define(:status, :body, :retry_after)

      # Worth another try: the provider is busy or failing for a moment. Every other status is an answer about the request itself.
      RETRIED_STATUSES = [ 429, 500, 502, 503, 504 ].freeze
      # The request never reached the provider, or the connection dropped: trying again sends nothing twice that matters,
      # the call only reads. A read timeout is not here: the user has already waited the full timeout once.
      RETRIED_ERRORS = [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError ].freeze

      # A Retry-After beyond this is not waited for: a person is waiting for an answer, and a refusal is better than a long hang.
      MAX_DELAY = 8

      attr_reader :read_timeout

      def initialize(open_timeout: 5, read_timeout: 30, max_retries: 2, base_delay: 0.5, transport: nil, sleeper: nil)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @base_delay = base_delay
        @transport = transport || method(:net_http)
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      # Returns [the parsed body, the latency in milliseconds]. A non-success status raises, with the provider's own message
      # when it sent one; `redact` removes what must never reach a log (the adapter knows what its keys look like).
      def post_json(url, headers:, body:, redact: ->(text) { text })
        started = monotonic_ms
        reply = with_retries { @transport.call(URI(url), headers.merge("Content-Type" => "application/json"), JSON.generate(body)) }
        latency = monotonic_ms - started

        raise_for(reply, redact) unless (200..299).cover?(reply.status)

        [ parse(reply.body), latency ]
      end

      private

      def with_retries
        attempt = 0
        loop do
          begin
            reply = yield
          rescue *RETRIED_ERRORS => e
            raise ConnectionError, "could not reach the provider (#{e.class})" if attempt >= @max_retries

            @sleeper.call(backoff(attempt))
            attempt += 1
            next
          rescue Net::ReadTimeout, Net::WriteTimeout
            raise TimeoutError, "the provider did not answer within #{@read_timeout}s"
          end
          return reply unless RETRIED_STATUSES.include?(reply.status) && attempt < @max_retries

          delay = delay_for(reply, attempt)
          return reply unless delay

          @sleeper.call(delay)
          attempt += 1
        end
      end

      # nil when the provider asks for a wait longer than MAX_DELAY: the reply is then raised as it is.
      def delay_for(reply, attempt)
        wanted = Float(reply.retry_after, exception: false)
        return backoff(attempt) unless wanted&.finite? && wanted >= 0

        wanted <= MAX_DELAY ? wanted : nil
      end

      # Exponential, with jitter so that clients failing together do not retry together.
      def backoff(attempt)
        [ @base_delay * (2**attempt) * (1 + rand), MAX_DELAY ].min
      end

      def raise_for(reply, redact)
        detail = provider_message(reply.body)
        message = "the provider answered #{reply.status}#{": #{redact.call(detail)}" if detail}"
        raise RateLimited, message if reply.status == 429

        raise ProviderError.new(message, status: reply.status)
      end

      # Providers put a readable reason in the error body; it is cut short, a body can be long.
      def provider_message(body)
        error = JSON.parse(body.to_s)["error"]
        message = error.is_a?(Hash) ? error["message"] : error
        message.is_a?(String) ? message.truncate(300) : nil
      rescue JSON::ParserError
        nil
      end

      def parse(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        raise InvalidResponse, "the provider's answer is not JSON"
      end

      def net_http(uri, headers, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body
        response = http.request(request)
        Reply.new(status: response.code.to_i, body: response.body, retry_after: response["retry-after"])
      end

      def monotonic_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end
  end
end
