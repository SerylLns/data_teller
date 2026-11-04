Rails.application.routes.draw do
  mount DataTeller::Engine => "/data_teller"
end
