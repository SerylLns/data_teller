require "rails/generators"

module DataTeller
  module Generators
    # Only the global configuration for now. Inferring dataset files from the models is a later ticket (T34).
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/data_teller.rb and the folder for the dataset declarations."

      # skip: without a terminal Thor treats the overwrite prompt as a yes, and would replace a real tenant resolver
      # with the commented-out template. Replacing the file takes an explicit --force.
      def create_configuration
        copy_file "data_teller.rb", DataTeller::Loader::GLOBAL_FILE, skip: true
        empty_directory File.dirname(DataTeller::Loader::DATASET_FILES)
      end

      def show_next_step
        say "\nNext: set `c.tenant` in #{DataTeller::Loader::GLOBAL_FILE}. The app does not boot until you do.", :yellow
      end
    end
  end
end
