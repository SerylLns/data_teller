module DataTeller
  class Error < StandardError; end

  # Raised for an invalid global setting (tenant, ui, on_invalid_config, ...).
  class ConfigurationError < Error; end

  # Raised for an invalid dataset, metric, dimension or segment declaration.
  class DeclarationError < Error; end
end
