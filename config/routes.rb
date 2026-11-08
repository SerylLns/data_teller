DataTeller::Engine.routes.draw do
  post "ask", to: "questions#create", as: :ask
  # Served from here, not through the host's asset pipeline: the gem installs whatever the host's front-end stack (ADR 0002).
  get "palette.js", to: "palette_assets#script", as: :palette_script, format: false
  get "palette.css", to: "palette_assets#style", as: :palette_style, format: false
end
