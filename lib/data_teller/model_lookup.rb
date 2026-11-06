module DataTeller
  # Reads the models' code only: no method here opens a database connection, so it is safe at boot (ADR 0004 D6).
  module ModelLookup
    module_function

    def active_record_class(name)
      klass = name.to_s.safe_constantize
      klass if klass.is_a?(Class) && klass < ActiveRecord::Base
    end

    # Walks associations from a model. Yields each reflection, so that callers can add their own rules.
    # Returns the class reached, or raises PathError saying where the walk stopped.
    def follow(klass, steps)
      steps.reduce(klass) do |current, step|
        reflection = current.reflect_on_association(step.to_sym)
        raise PathError, "#{current.name} has no association :#{step}" unless reflection
        raise PathError, "#{current.name}.#{step} is polymorphic, its target is only known per row" if reflection.polymorphic?

        yield current, step, reflection if block_given?
        target_of(current, step, reflection)
      end
    end

    # A column of a metric, which may be a path: "line_items.quantity" gives [LineItem, "quantity"]. nil when unusable.
    def column_owner(klass, column)
      *steps, name = column.to_s.split(".")
      [ follow(klass, steps), name ]
    rescue PathError
      nil
    end

    # `scope` and `enum` register the name here, unlike a class method, which could do anything when called.
    # Private API, stable across recent Rails: if it goes away the rescue makes every scope refused, not trusted.
    def declared_scope?(klass, name)
      klass.send(:generated_relation_methods).method_defined?(name)
    rescue NoMethodError
      false
    end

    # What the host app already treats as sensitive: its filter_parameters reach the models through filter_attributes.
    def sensitive_for_host?(klass, column)
      return true if klass.encrypted_attributes&.include?(column.to_sym)

      ActiveSupport::ParameterFilter.new(klass.filter_attributes).filter_param(column.to_s, "x") != "x"
    end

    def target_of(current, step, reflection)
      reflection.klass
    rescue NameError
      raise PathError, "#{current.name}.#{step} points to #{reflection.class_name}, which does not exist"
    end

    class PathError < Error; end
  end
end
