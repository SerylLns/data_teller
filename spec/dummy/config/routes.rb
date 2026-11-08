Rails.application.routes.draw do
  mount DataTeller::Engine => "/data_teller"

  # FAKE sign-in to try the palette, never outside development and test (T13b).
  if Rails.env.local?
    root "dummy_sessions#show"
    post "dummy_sign_in", to: "dummy_sessions#create"
  end
end
