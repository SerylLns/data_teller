module DataTeller
  # The next page of a list (ADR 0016 D4). The query and the cursor come from the client: they are parsed here, then validated by
  # DataTeller.rows exactly as the model's output is, so a query written by hand can do nothing the model could not be steered into.
  class RowsController < ApplicationController
    # A list query and its cursor are a few hundred bytes; anything far larger is not one the palette sent.
    MAX_PARAM = 10_000

    def create
      user = DataTeller.config.current_user_for(request)
      return head(:unauthorized) unless user

      query = parsed(params[:data_teller_query])
      after = parsed(params[:data_teller_after])
      return head(:unprocessable_entity) unless query.is_a?(Hash) && after.is_a?(Hash)

      outcome = DataTeller.rows(query, user: user, after: after)
      I18n.with_locale(DataTeller.config.locale_for(user)) do
        if outcome.status == :answered
          render partial: "data_teller/questions/list_page", locals: { outcome: outcome, total: params[:data_teller_total].to_i }
        else
          render partial: "data_teller/questions/outcome", locals: { outcome: outcome }
        end
      end
    end

    private

    def parsed(text)
      return nil unless text.is_a?(String) && text.bytesize <= MAX_PARAM

      JSON.parse(text, max_nesting: 10)
    rescue JSON::ParserError, JSON::NestingError
      nil
    end
  end
end
