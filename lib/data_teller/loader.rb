module DataTeller
  # Evaluates the declaration files like initializers (ADR 0004 D1): config/data_teller.rb, then one file per dataset
  # in config/data_teller/. They are developer-authored Ruby, trusted at the same level as an initializer.
  #
  # Everything is built into fresh objects, so that a failed or partial load can never reach the running engine:
  # DataTeller.boot! publishes the result only after it has been validated.
  module Loader
    GLOBAL_FILE = "config/data_teller.rb".freeze
    DATASET_FILES = "config/data_teller/*.rb".freeze
    CONTEXT_KEY = :data_teller_loading

    Context = Data.define(:config, :registry)
    Loaded = Data.define(:config, :registry, :errors, :skipped_checks)

    module_function

    def configured?(root)
      files(root).any?
    end

    # Reads every file, whatever happens in the others, so that one run reports as much as possible.
    def call(root)
      root = Pathname(root)
      paths = files(root)
      errors = []
      skipped_checks = []
      return Loaded.new(**empty_context.to_h, errors: [ not_configured ], skipped_checks: %i[tenant exposure]) if paths.empty?

      context = capture do
        paths.each do |file|
          load file.to_s
        rescue StandardError, ScriptError => e
          errors.concat(problems_in(file, root, e))
          # What the file failed to declare says nothing about the app: these checks would report false problems.
          skipped_checks |= file == root.join(GLOBAL_FILE) ? %i[tenant exposure] : %i[exposure]
        end
      end

      Loaded.new(**context.to_h, errors: errors, skipped_checks: skipped_checks)
    end

    # Where DataTeller.configure and DataTeller.refine write while the block runs.
    def capture
      context = empty_context
      previous = current
      Thread.current[CONTEXT_KEY] = context
      yield context
      context
    ensure
      Thread.current[CONTEXT_KEY] = previous
    end

    def current
      Thread.current[CONTEXT_KEY]
    end

    def files(root)
      root = Pathname(root)
      [ root.join(GLOBAL_FILE), *root.glob(DATASET_FILES).sort ].select(&:file?)
    end

    def empty_context
      Context.new(config: Configuration.new, registry: Registry.new)
    end

    def not_configured
      "no configuration found: run `rails generate data_teller:install`"
    end

    def problems_in(file, root, error)
      location = error.backtrace_locations&.find { |frame| frame.absolute_path == file.to_s }
      place = [ file.relative_path_from(root), location&.lineno ].compact.join(":")

      if error.is_a?(DeclarationError)
        error.problems.map { |problem| "#{place}: #{problem}" }
      elsif error.is_a?(Error)
        [ "#{place}: #{error.message}" ]
      else
        [ "#{place}: #{error.class}: #{error.message}" ]
      end
    end
  end
end
