module DataTeller
  # A queryable column or dotted path (customer.city). Type is inferred from the model later, never copied here (ADR 0004 D3).
  class Dimension < Data.define(:name, :column, :type, :time, :lookup, :filter, :group, :max_groups, :sensitive, :roles)
    LOOKUPS = %i[trigram hybrid].freeze

    # group: nil means "decide from the inferred cardinality class"; true/false is an explicit developer choice.
    def initialize(name:, column: nil, type: nil, time: false, lookup: nil, filter: true, group: nil, max_groups: nil,
                   sensitive: false, roles: nil)
      unless lookup.nil? || LOOKUPS.include?(lookup)
        raise DeclarationError, "dimension #{name.inspect}: lookup must be one of #{LOOKUPS.inspect}, got #{lookup.inspect}"
      end
      unless max_groups.nil? || (max_groups.is_a?(Integer) && max_groups.positive?)
        raise DeclarationError, "dimension #{name.inspect}: max_groups must be a positive Integer, got #{max_groups.inspect}"
      end

      super(
        name: NameFormat.ensure!(name, "dimension"),
        column: (column || name).to_s.freeze,
        type: type&.to_sym,
        time: time == true,
        lookup: lookup,
        filter: filter != false,
        group: group.nil? ? nil : group == true,
        max_groups: max_groups,
        sensitive: sensitive == true,
        roles: NameFormat.roles(roles, "dimension")
      )
    end
  end
end
