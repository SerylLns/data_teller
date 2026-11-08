module DataTeller
  # From a question and a user to an outcome (ADR 0010 D1): the way in for the palette and for any other visual. Everything that stops
  # a question stops it before a provider is paid: an engine that is off, no tenant, no dataset for the role, a question too long.
  class Ask
    # A question is a sentence. Beyond that it is a way to spend the host's budget, or an attempt on the prompt.
    MAX_QUESTION_LENGTH = 500

    def self.call(question, user:, now: Time.current)
      new(question, user, now).call
    end

    def initialize(question, user, now)
      @question = question
      @user = user
      @now = now
    end

    def call
      return refused(:engine_disabled) unless DataTeller.enabled?
      return refused(:invalid_question) unless valid_question?

      llm = DataTeller.config.llm
      return refused(:llm_unavailable) unless llm

      tenant = DataTeller.config.tenant_for(@user)
      return refused(:no_tenant) unless tenant

      # A role that sees nothing gets the answer an unknown dataset gets: it must not learn that others see something (ADR 0001 D5).
      catalog = Catalog.for_user(@user)
      return refused(:unknown_dataset) if catalog.datasets.none? { |entry| entry.metrics.any? }

      time_zone = DataTeller.config.time_zone_for(tenant)
      return refused(:unsupported_query) unless time_zone

      generated = Pipeline.new(llm: llm, router_llm: DataTeller.config.router_llm)
                          .call(@question.strip, catalog: catalog, today: @now.in_time_zone(time_zone).to_date, time_zone: time_zone)
      log(generated)
      QueryRunner.call(generated.output, user: @user, now: @now)
    rescue LLM::Error => e
      # The class only: a provider's message may quote the prompt. The user gets the same refusal whatever went wrong.
      Rails.logger&.error("[DataTeller] the provider failed: #{e.class}")
      refused(:llm_unavailable)
    end

    private

    def valid_question?
      @question.is_a?(String) && @question.strip.present? && @question.length <= MAX_QUESTION_LENGTH
    end

    # Cost and latency for the host's logs. Never the question: it is the end user's, and may hold personal data.
    def log(generated)
      Rails.logger&.info("[DataTeller] asked: #{generated.input_tokens} tokens in (#{generated.cached_input_tokens} cached), " \
                         "#{generated.output_tokens} out, #{generated.latency_ms} ms, #{generated.route ? "routed to #{generated.route.size}" : 'whole catalog'}, #{generated.model}")
    end

    def refused(reason)
      QueryRunner::Outcome.new(status: :refused, query: nil, result: nil, refusal: QueryValidator::Refusal.new(reason: reason), trace: nil)
    end
  end
end
