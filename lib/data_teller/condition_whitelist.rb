require "date"

module DataTeller
  # What a condition from the host's code may be made of (ADR 0004 D4): comparisons of a column of the model to plain values,
  # joined by AND, OR and NOT. Each node must be in this list. Looking for what is dangerous missed a raw attribute name, a
  # sub-query and a bare OR, three times the same mistake: whatever was not thought of went through.
  #
  # Raw SQL is refused everywhere, default_scope included. Judging it from its text needs a SQL parser: counting parentheses
  # missed those inside a string literal, `'(' <> 'x') OR (1=1 OR ')' = 'y'`, which put an OR outside the tenant filter's AND.
  class ConditionWhitelist
    # Methods, not constants: naming these at load time would load Active Record before the host's initializers.
    def self.comparisons
      @comparisons ||= [ Arel::Nodes::Equality, Arel::Nodes::NotEqual, Arel::Nodes::GreaterThan,
                         Arel::Nodes::GreaterThanOrEqual, Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual ].freeze
    end

    def self.bound_values
      @bound_values ||= [ Arel::Nodes::BindParam, ActiveRecord::Relation::QueryAttribute ].freeze
    end

    def self.plain_values
      @plain_values ||= [ NilClass, TrueClass, FalseClass, Numeric, Symbol, Date, Time, ActiveSupport::TimeWithZone ].freeze
    end

    def initialize(klass)
      @klass = klass
    end

    # What is not accepted in this condition, to name in a message, or nil if all of it is. to_s and not name: an anonymous class
    # has no name, and nil here would accept it.
    def refused_part(node)
      kind = node.class

      if kind == Arel::Nodes::And then first_refused(operands_of(node))
      elsif kind == Arel::Nodes::Grouping then grouped_part(node.expr)
      elsif kind == Arel::Nodes::Not then refused_part(node.expr)
      elsif self.class.comparisons.include?(kind) then first_refused_operand([ node.left, node.right ])
      elsif kind == Arel::Nodes::In || kind == Arel::Nodes::NotIn then list_part(node)
      elsif kind == Arel::Nodes::Between then between_part(node)
      elsif kind == Arel::Nodes::HomogeneousIn then homogeneous_in_part(node)
      elsif kind == Arel::Nodes::SqlLiteral || kind == Arel::Nodes::BoundSqlLiteral then "raw SQL"
      elsif kind == Arel::Nodes::Or then "an OR without parentheses"
      else kind.to_s
      end
    end

    private

    # Only inside parentheses can an OR not take the conditions next to it along: `a OR b AND tenant` ignores the tenant on one
    # side. Rails always adds them, a node built by hand may not.
    def grouped_part(expr)
      expr.instance_of?(Arel::Nodes::Or) ? first_refused(operands_of(expr)) : refused_part(expr)
    end

    def list_part(node)
      return node.right.class.to_s unless node.right.is_a?(Array)

      first_refused_operand([ node.left, *node.right ])
    end

    def between_part(node)
      return node.right.class.to_s unless node.right.instance_of?(Arel::Nodes::And)

      first_refused_operand([ node.left, *operands_of(node.right) ])
    end

    def homogeneous_in_part(node)
      attribute_part(node.attribute) || ("a value that is not plain" unless node.values.all? { |value| plain?(value) })
    end

    def operand_part(node)
      if node.instance_of?(Arel::Attributes::Attribute) then attribute_part(node)
      elsif self.class.bound_values.include?(node.class) then nil
      elsif node.instance_of?(Arel::Nodes::Casted) || node.instance_of?(Arel::Nodes::Quoted)
        "a value that is not plain" unless plain?(node.value)
      else node.class.to_s
      end
    end

    def attribute_part(attribute)
      table = attribute.relation
      unless table.instance_of?(Arel::Table) && table.table_alias.nil? && table.name == @klass.table_name
        return "a column that is not on #{@klass.table_name}"
      end

      "something that is not a column of #{@klass.table_name}" unless @klass.column_names.include?(attribute.name.to_s)
    end

    def plain?(value)
      value.instance_of?(String) || self.class.plain_values.any? { |kind| value.is_a?(kind) }
    end

    # Or holds two children on Rails 7.2, a list since.
    def operands_of(node)
      node.respond_to?(:children) ? node.children : [ node.left, node.right ]
    end

    def first_refused(nodes)
      nodes.lazy.filter_map { |node| refused_part(node) }.first
    end

    def first_refused_operand(nodes)
      nodes.lazy.filter_map { |node| operand_part(node) }.first
    end
  end
end
