module DataTeller
  # Names end up in the JSON schema sent to the LLM and in the query format (query_v1.json),
  # so they follow the same strict pattern.
  module NameFormat
    PATTERN = /\A[a-z][a-z0-9_]*\z/

    def self.ensure!(value, kind)
      name = value.to_s
      return name.to_sym if PATTERN.match?(name)

      raise DeclarationError, "#{kind} name must match #{PATTERN.inspect}, got #{value.inspect}"
    end

    def self.roles(value, kind)
      return nil if value.nil?

      list = Array(value).map { |role| ensure!(role, "#{kind} role") }.uniq.freeze
      raise DeclarationError, "#{kind} roles must not be empty (omit roles to inherit from the dataset)" if list.empty?

      list
    end
  end
end
