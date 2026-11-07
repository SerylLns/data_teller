module DataTeller
  # For the developer's trace only (ADR 0005 D5): of the names a query was refused on, those that exist for other roles.
  # The refusal itself says "unknown" either way, on purpose (ADR 0001 D5); the developer debugging "why does Max get no
  # revenue" needs the difference. This reads names the user may not see, which is why it never leaves the trace.
  class HiddenNames
    NAME_KEYS = %w[dataset metric dimension segment].freeze

    def initialize(query, user_catalog)
      @query = query
      @user_catalog = user_catalog
    end

    # [{ pointer: "/metric", visible_to: [:admin] }], for each refused name that another role sees.
    def call(problems)
      problems.map { |problem| problem[:pointer] }.uniq.filter_map do |pointer|
        kind = pointer.split("/").last
        next unless NAME_KEYS.include?(kind)

        name = name_at(pointer)
        next unless name.is_a?(String) && !visible?(@user_catalog, kind, name)

        roles = other_roles.select { |role| visible?(Catalog.for(role), kind, name) }
        { pointer: pointer, visible_to: roles } if roles.any?
      end
    end

    private

    def name_at(pointer)
      pointer.split("/").drop(1).reduce(@query) do |node, token|
        case node
        when Hash then node[token]
        when Array then token.match?(/\A\d+\z/) ? node[token.to_i] : nil
        end
      end
    end

    def visible?(catalog, kind, name)
      return catalog.datasets.any? { |entry| entry.name.to_s == name } if kind == "dataset"

      entry = catalog.datasets.find { |candidate| candidate.name.to_s == @query["dataset"] }
      return false unless entry

      names = { "metric" => entry.metrics, "dimension" => entry.fields, "segment" => entry.segments }.fetch(kind)
      names.any? { |item| item.name.to_s == name }
    end

    # Every role a declaration names. The user's own roles never see a name refused for them, so they need no removing.
    def other_roles
      @other_roles ||= DataTeller.registry.datasets.flat_map do |dataset|
        items = [ dataset.metrics, dataset.dimensions, dataset.segments ].flat_map(&:values)
        [ *dataset.roles, *items.flat_map { |item| Array(item.roles) } ]
      end.uniq.sort
    end
  end
end
