module DataTeller
  # A queryable column of the dataset's model. Paths like customer.city are derived from exposed models, never written
  # here (ADR 0001 D4). The type is inferred from the model later, and only overridden here (ADR 0004 D3).
  class Dimension < Data.define(:name, :column, :type, :time, :lookup, :filter, :group, :max_groups, :sensitive, :roles)
    LOOKUPS = %i[trigram hybrid].freeze
    TYPES = %i[date enum string number boolean].freeze

    # group: nil means "decide from the inferred cardinality class"; true/false is an explicit developer choice.
    def initialize(name:, column: nil, type: nil, time: false, lookup: nil, filter: true, group: nil, max_groups: nil,
                   sensitive: false, roles: nil)
      unless lookup.nil? || LOOKUPS.include?(lookup)
        raise DeclarationError, "dimension #{name.inspect}: lookup must be one of #{LOOKUPS.inspect}, got #{lookup.inspect}"
      end
      unless max_groups.nil? || (max_groups.is_a?(Integer) && max_groups.positive?)
        raise DeclarationError, "dimension #{name.inspect}: max_groups must be a positive Integer, got #{max_groups.inspect}"
      end

      unless group.nil? || group == true || group == false
        raise DeclarationError, "dimension #{name.inspect}: group must be true, false or nil, got #{group.inspect}"
      end
      unless type.nil? || ((type.is_a?(Symbol) || type.is_a?(String)) && TYPES.include?(type.to_sym))
        raise DeclarationError, "dimension #{name.inspect}: type must be one of #{TYPES.inspect}, got #{type.inspect}"
      end

      super(
        name: NameFormat.ensure!(name, "dimension"),
        column: NameFormat.column(column || name, "dimension #{name.inspect}").freeze,
        type: type&.to_sym,
        time: NameFormat.boolean(time, "dimension #{name.inspect}: time"),
        lookup: lookup,
        filter: NameFormat.boolean(filter, "dimension #{name.inspect}: filter"),
        group: group,
        max_groups: max_groups,
        sensitive: NameFormat.boolean(sensitive, "dimension #{name.inspect}: sensitive"),
        roles: NameFormat.roles(roles, "dimension")
      )
    end
  end
end
