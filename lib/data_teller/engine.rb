module DataTeller
  class Engine < ::Rails::Engine
    isolate_namespace DataTeller

    # Runs once at boot, and again on each code reload in development, so edited declarations are picked up.
    config.to_prepare do
      DataTeller::Loader.load!(Rails.root)
    end
  end
end
