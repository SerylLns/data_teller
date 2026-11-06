# DataTeller global configuration. One file per exposed model goes in config/data_teller/.
DataTeller.configure do |c|
  # REQUIRED: returns the tenant of the current user. The compiler scopes every query to it.
  # The app does not boot until this line is set: there is no safe default to guess.
  # c.tenant { |user| user.account }

  # Returns the roles of the current user. No resolver, nil or an error all mean no access.
  # c.roles { |user| user.roles }

  # Models that can be queried, each one declared in config/data_teller/<dataset>.rb.
  # A model that is not listed here cannot be queried.
  # c.expose Order

  # What to do when this configuration is invalid. In both cases the engine stays off.
  #   :raise   (default) the app refuses to boot
  #   :disable the app boots without the engine, with an error in the log
  # c.on_invalid_config = :raise
end
