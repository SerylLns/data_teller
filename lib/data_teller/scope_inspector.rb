module DataTeller
  # What a scope may bring into a query (ADR 0004 D4): conditions from ConditionWhitelist, and nothing else. A whitelist on
  # purpose: a list of forbidden clauses missed `from`, and a redefined tenant column then passed the tenant filter while
  # filtering nothing.
  #
  # Used by the compiler on every query, and by `rake data_teller:check`, so that both say the same thing. Reads the columns of
  # the model, so never at boot (ADR 0004 D6).
  module ScopeInspector
    class Rejected < Error; end

    # What a default_scope may hold: it applies to every query without anyone naming it.
    # Order is dropped by the compiler before aggregating, it cannot change which rows are read.
    ALLOWED_IN_DEFAULT_SCOPE = %i[where order].freeze

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

      part = ConditionWhitelist.new(klass).refused_part(added.ast)
      raise Rejected, "scope :#{name} holds #{part}; a segment can only compare columns of #{klass.name} to plain values, with a hash or Arel" if part

      # In its own parentheses, whatever it holds: nothing in it can then reach the tenant filter added next to it.
      Arel::Nodes::Grouping.new(added.ast)
    end

    # Raw SQL is accepted here and not in a segment: `where("deleted_at IS NULL")` is common, and the host cannot write its
    # default_scope differently for this gem.
    def check_default_scope(klass)
      relation = klass.all
      extra = present_values(relation).keys - ALLOWED_IN_DEFAULT_SCOPE
      raise Rejected, "#{klass.name}: default_scope uses #{extra.first}, which could change the rows the tenant filter sees" if extra.any?

      part = ConditionWhitelist.new(klass, raw_sql_allowed: true).refused_part(relation.where_clause.ast)
      raise Rejected, "#{klass.name}: default_scope holds #{part}, which could change the rows the tenant filter sees" if part
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
  end
end
