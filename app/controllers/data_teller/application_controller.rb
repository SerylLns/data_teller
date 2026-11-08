module DataTeller
  class ApplicationController < ActionController::Base
    # Explicit, for a host whose defaults turn it off: every question is paid for, and runs as the signed-in user.
    protect_from_forgery with: :exception
    before_action :require_engine

    # A fetch has no use for a Rails error page.
    rescue_from ActionController::InvalidAuthenticityToken do
      head 422
    end

    private

    # Fail closed (ADR 0004 D6): the routes exist even when the configuration was refused at boot.
    def require_engine
      head :service_unavailable unless DataTeller.enabled?
    end
  end
end
