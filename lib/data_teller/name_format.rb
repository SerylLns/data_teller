module DataTeller
  # Names end up in the JSON schema sent to the LLM and in the query format (query_v1.json), and columns end up in SQL
  # identifiers, so both follow strict patterns. Same pattern and length limit as the `name` definition of the schema.
  module NameFormat
    PATTERN = /\A[a-z][a-z0-9_]*\z/
    MAX_LENGTH = 80
    # Column names are the host app's: legacy schemas may use camelCase or a leading underscore.
    COLUMN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    # Paths are only legal in metrics, for has_many data, with the depth limit of ADR 0001 D4.
    COLUMN_PATH = /\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*){0,2}\z/

    def self.ensure!(value, kind)
      name = value.to_s
      unless value.is_a?(Symbol) || value.is_a?(String)
        raise DeclarationError, "#{kind} name must be a name matching #{PATTERN.inspect}, got #{value.class}"
      end
      unless PATTERN.match?(name)
        raise DeclarationError, "#{kind} name must match #{PATTERN.inspect}, got #{value.inspect}"
      end
      raise DeclarationError, "#{kind} name must have at most #{MAX_LENGTH} characters, got #{name.size}" if name.size > MAX_LENGTH

      name.to_sym
    end

    def self.roles(value, kind)
      return nil if value.nil?

      list = Array(value).map { |role| ensure!(role, "#{kind} role") }.uniq.freeze
      raise DeclarationError, "#{kind} roles must not be empty (omit roles to inherit from the dataset)" if list.empty?

      list
    end

    def self.column(value, kind, pattern: COLUMN)
      unless (value.is_a?(Symbol) || value.is_a?(String)) && pattern.match?(value.to_s)
        raise DeclarationError, "#{kind}: column must be a column name, got #{value.is_a?(Proc) ? 'a Proc' : value.inspect}"
      end

      value.to_s
    end

    # A silently coerced flag can switch a protection off, so anything but a real boolean is refused.
    def self.boolean(value, kind)
      return value if value == true || value == false

      raise DeclarationError, "#{kind} must be true or false, got #{value.inspect}"
    end
  end
end
