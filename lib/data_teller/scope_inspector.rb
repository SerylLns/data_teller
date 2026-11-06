module DataTeller
  # What a scope may bring into a query (ADR 0004 D4): structured conditions, and nothing else. A whitelist on purpose: a list
  # of forbidden clauses missed `from`, and a redefined tenant column then passed the tenant filter while filtering nothing.
  #
  # Used by the compiler on every query, and by `rake data_teller:check`, so that both say the same thing.
  module ScopeInspector
    class Rejected < Error; end

    # What a default_scope may hold: it applies to every query without anyone naming it.
    # Order is dropped by the compiler before aggregating, it cannot change which rows are read.
    ALLOWED_IN_DEFAULT_SCOPE = %i[where order].freeze
    # Raw SQL is accepted in a default_scope (`where("deleted_at IS NULL")` is common), as long as it cannot end its own
    # parentheses or the statement: `1=1) OR (1=1` would put the OR outside the AND of the tenant filter.
    UNSAFE_RAW_SQL = /--|\/\*|\*\/|;/

    module_function

    # The conditions a scope adds to the model's default ones, as one Arel node, or nil if it adds none.
    # Conditions are returned rather than a relation to merge: `merge` replaces an earlier condition on the same column.
    def conditions(klass, name)
      raise Rejected, "#{klass.name} has no scope :#{name}" unless ModelLookup.declared_scope?(klass, name)

      relation = call_scope(klass, name)
      raise Rejected, "scope :#{name} does not return a relation of #{klass.name}" unless relation.is_a?(ActiveRecord::Relation) && relation.klass == klass

      check_only_conditions(klass, name, relation)

      added = relation.where_clause - klass.all.where_clause
      return nil if added.empty?

      raise Rejected, "scope :#{name} uses raw SQL, which could escape the tenant filter; write it with a hash or Arel" if raw_sql?(added.ast)

      added.ast
    end

    def check_default_scope(klass)
      relation = klass.all
      extra = present_values(relation).keys - ALLOWED_IN_DEFAULT_SCOPE
      raise Rejected, "#{klass.name}: default_scope uses #{extra.first}, which could change the rows the tenant filter sees" if extra.any?

      raw_fragments(relation.where_clause.ast).each do |fragment|
        next if safe_raw_sql?(fragment)

        raise Rejected, "#{klass.name}: default_scope has raw SQL that could escape the tenant filter"
      end
    end

    def call_scope(klass, name)
      klass.public_send(name)
    rescue ArgumentError
      raise Rejected, "scope :#{name} takes an argument, a segment has none to give it"
    end

    # Compared to the model's defaults, so that a default_scope is judged by check_default_scope and not blamed on each scope.
    def check_only_conditions(klass, name, relation)
      defaults = present_values(klass.all)
      extra = present_values(relation).except(:where).reject { |key, value| defaults[key] == value }.keys

      raise Rejected, "scope :#{name} uses #{extra.first}, which would change the result; a segment can only hold conditions" if extra.any?
    end

    # `or` leaves empty components behind (having, references): they change nothing.
    def present_values(relation)
      relation.values.reject { |_key, value| value.blank? }
    end

    def raw_sql?(node)
      raw_fragments(node).any?
    end

    # Arel has no general way to walk a node, and a type missed here would be a hole: instance variables reach everything.
    def raw_fragments(node)
      case node
      when Arel::Nodes::SqlLiteral then [ node.to_s ]
      when String then [ node ]
      when Arel::Nodes::Quoted, Arel::Nodes::BindParam, Arel::Attributes::Attribute then []
      when Arel::Nodes::Node then node.instance_variables.flat_map { |name| raw_fragments(node.instance_variable_get(name)) }
      when Array then node.flat_map { |item| raw_fragments(item) }
      else []
      end
    end

    def safe_raw_sql?(fragment)
      return false if UNSAFE_RAW_SQL.match?(fragment)

      depth = 0
      fragment.each_char do |char|
        depth += 1 if char == "("
        depth -= 1 if char == ")"
        return false if depth.negative?
      end
      depth.zero?
    end
  end
end
