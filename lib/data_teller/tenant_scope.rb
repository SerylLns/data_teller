module DataTeller
  # The tenant filter, in one place (ADR 0005 D1). Each condition is a sub-query, so it touches no join of the query and
  # is written the same way for any table at any depth. The tenant id is always a bound parameter.
  class TenantScope
    def initialize(tenant)
      @tenant = tenant
    end

    # path is the dataset's tenant_path, nil on the tenant model itself. The boot checks all this already. These are not
    # redundant: comparing ids across tables by mistake would return another tenant's rows, so it must stop here too.
    def condition_for(klass, path)
      if path.nil?
        raise Compiler::Refused.new(:unsupported_query, "#{klass.name} has no tenant_path") unless @tenant.is_a?(klass)

        return key_equals(klass, klass.primary_key, @tenant.public_send(klass.primary_key))
      end

      step, *rest = path
      reflection = klass.reflect_on_association(step)
      unless reflection&.belongs_to? && !reflection.polymorphic?
        raise Compiler::Refused.new(:unsupported_query, "#{klass.name}.#{step} is not a belongs_to association")
      end

      key = reflection.foreign_key

      if rest.empty?
        unless @tenant.is_a?(reflection.klass)
          raise Compiler::Refused.new(:unsupported_query, "the path of #{klass.name} ends at #{reflection.klass.name}, the tenant is a #{@tenant.class.name}")
        end

        key_equals(klass, key, @tenant.public_send(reflection.association_primary_key))
      else
        klass.arel_table[key].in(parent_ids(reflection, rest))
      end
    end

    # The last check before anything runs (ADR 0004 D4): each filter must be in the relation that is about to execute.
    # Identity on purpose: a condition that merely looks the same was not built here.
    def present_in?(relation, conditions)
      predicates = flatten(relation.where_clause.ast)

      conditions.all? { |condition| predicates.any? { |predicate| predicate.equal?(condition) } }
    end

    private

    # unscoped: it answers "who owns this row", which a soft-delete default_scope on the parent must not change.
    def parent_ids(reflection, rest)
      parent = reflection.klass

      parent.unscoped.where(condition_for(parent, rest)).select(reflection.association_primary_key).arel
    end

    def key_equals(klass, column, value)
      klass.arel_table[column].eq(Compiler.bind(klass, column, value))
    end

    def flatten(node)
      node.is_a?(Arel::Nodes::And) ? node.children.flat_map { |child| flatten(child) } : [ node ]
    end
  end
end
