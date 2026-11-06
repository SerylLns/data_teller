module DataTeller
  # Loads the declaration files like initializers (ADR 0004 D1): config/data_teller.rb, then one file per dataset
  # in config/data_teller/. They are developer-authored Ruby, trusted at the same level as an initializer.
  module Loader
    module_function

    # Only the registry is rebuilt on reload. The global file runs again too, but its settings are idempotent,
    # so an app that also configures DataTeller from an initializer does not lose anything.
    def load!(root)
      DataTeller.registry_reset!

      files(root).each do |file|
        load file.to_s
      rescue DeclarationError, ConfigurationError => e
        raise e.class, "#{file.relative_path_from(root)}: #{e.message}", e.backtrace
      end
    end

    def files(root)
      root = Pathname(root)
      [ root.join("config/data_teller.rb"), *root.glob("config/data_teller/*.rb").sort ].select(&:file?)
    end
  end
end
