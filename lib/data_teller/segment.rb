module DataTeller
  # Declarative `where:` is the norm; `scope:` is a guarded escape hatch (ADR 0004 D4).
  # A declarative condition holds data only, never code: a relative offset like { days_ago: 30 } is resolved by the
  # compiler with the tenant time zone, whereas a lambda would be evaluated blind to it.
  class Segment < Data.define(:name, :where, :scope, :roles)
    def initialize(name:, where: nil, scope: nil, roles: nil)
      raise DeclarationError, "segment #{name.inspect}: give exactly one of where: or scope:" if where.nil? == scope.nil?

      super(
        name: NameFormat.ensure!(name, "segment"),
        where: where.nil? ? nil : condition(name, where),
        scope: scope.nil? ? nil : NameFormat.ensure!(scope, "segment #{name.inspect}: scope"),
        roles: NameFormat.roles(roles, "segment")
      )
    end

    def scope?
      !scope.nil?
    end

    private

    def condition(name, value)
      unless value.is_a?(Hash) && !value.empty?
        raise DeclarationError, "segment #{name.inspect}: where: must be a non-empty Hash, got #{value.inspect}"
      end

      value.each_with_object({}) do |(key, item), out|
        unless (key.is_a?(Symbol) || key.is_a?(String)) && NameFormat::PATTERN.match?(key.to_s)
          raise DeclarationError, "segment #{name.inspect}: where: key must be a name, got #{key.inspect}"
        end

        out[key.to_sym] = frozen_data(name, item)
      end.freeze
    end

    # An allowlist: a Date literal cannot be told apart from Date.today, and anything else could hide code.
    # `case` on purpose: ActiveSupport::Duration overrides is_a?(Numeric) but not Numeric === duration.
    def frozen_data(name, value)
      case value
      when Hash then condition(name, value)
      when Array then value.map { |item| frozen_data(name, item) }.freeze
      when String then value.dup.freeze
      when Symbol, Numeric, true, false, nil then value
      else
        raise DeclarationError, "segment #{name.inspect}: where: holds data, not code; got #{value.class}. " \
                                "Use a relative offset like { days_ago: 30 }, or scope: for an existing scope"
      end
    end
  end
end
