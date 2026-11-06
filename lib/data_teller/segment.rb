module DataTeller
  # Declarative `where:` is the norm; `scope:` is a guarded escape hatch (ADR 0004 D4).
  # A declarative condition holds data only, never code: a relative offset like { days_ago: 30 } is resolved by the
  # compiler with the tenant time zone, whereas a lambda would be evaluated blind to it.
  class Segment < Data.define(:name, :where, :scope, :roles)
    def initialize(name:, where: nil, scope: nil, roles: nil)
      raise DeclarationError, "segment #{name.inspect}: give exactly one of where: or scope:" if where.nil? == scope.nil?

      super(
        name: NameFormat.ensure!(name, "segment"),
        where: where.nil? ? nil : deep_freeze_data(name, where),
        scope: scope&.to_sym,
        roles: NameFormat.roles(roles, "segment")
      )
    end

    def scope?
      !scope.nil?
    end

    private

    def deep_freeze_data(name, value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), out| out[k.to_sym] = deep_freeze_data(name, v) }.freeze
      when Array
        value.map { |v| deep_freeze_data(name, v) }.freeze
      when Proc, Method
        raise DeclarationError, "segment #{name.inspect}: where: holds data, not code; use scope: for an existing scope"
      else
        value.frozen? ? value : value.dup.freeze
      end
    end
  end
end
