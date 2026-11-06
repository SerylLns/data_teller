module DataTeller
  class Error < StandardError; end

  # Raised for an invalid global setting (tenant, ui, on_invalid_config, ...).
  class ConfigurationError < Error; end

  # Raised for an invalid dataset, metric, dimension or segment declaration.
  # A refine block can hold several mistakes; `problems` lets the report list each of them.
  class DeclarationError < Error
    attr_reader :problems

    def initialize(problems = nil)
      @problems = Array(problems)
      super(@problems.join("; "))
    end
  end
end
