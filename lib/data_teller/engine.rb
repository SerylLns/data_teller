module DataTeller
  class Engine < ::Rails::Engine
    isolate_namespace DataTeller

    # Runs once at boot, and again on each code reload in development.
    config.to_prepare do
      DataTeller.boot!(Rails.root)
    end

    # Declaration files are not autoloaded, so without a watcher editing one would not trigger a reload, and the app
    # would keep serving the old declarations with no error until an unrelated file changed.
    initializer "data_teller.watch_declarations" do |app|
      next unless app.config.enable_reloading

      watcher = app.config.file_watcher.new(
        [ app.root.join(DataTeller::Loader::GLOBAL_FILE).to_s ],
        { app.root.join(File.dirname(DataTeller::Loader::DATASET_FILES)).to_s => [ "rb" ] }
      ) { }

      app.reloaders << watcher
      app.reloader.to_run { watcher.execute_if_updated }
    end
  end
end
