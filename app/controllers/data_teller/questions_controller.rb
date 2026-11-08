module DataTeller
  # The palette's endpoint. Answers an HTML fragment (ADR 0002). A refusal is an answer: only a missing user is an HTTP error.
  # There is no per-user limit until T32: every question here is paid to the provider, so do not expose it in production before that.
  class QuestionsController < ApplicationController
    def create
      user = DataTeller.config.current_user_for(request)
      return head(:unauthorized) unless user

      outcome = DataTeller.ask(params[:data_teller_question], user: user)
      I18n.with_locale(DataTeller.config.locale_for(user)) do
        render partial: "data_teller/questions/outcome", locals: { outcome: outcome }
      end
    end
  end
end
