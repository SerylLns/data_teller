# FAKE authentication: picks a seeded user with no password, to try the palette under each role. Dummy app only, routed in development and
# test only. Never copy this into an app.
class DummySessionsController < ActionController::Base
  def show
    @users = User.includes(:account).order(:id)
    @current = User.find_by(id: session[:dummy_user_id])
  end

  def create
    session[:dummy_user_id] = User.find_by(id: params[:user_id])&.id
    redirect_to root_path
  end
end
