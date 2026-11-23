module DataTeller
  # A condition on every query that reads the dataset, joined tables included (ADR 0014). The grammar of a segment, without a name or
  # roles: nobody chooses it. Validation is the segment's own, so that both accept exactly the same conditions.
  class Always < Data.define(:where, :scope)
    def initialize(where: nil, scope: nil)
      segment = Segment.new(name: :always, where: where, scope: scope)
      # A rule of the business does not move with today's date.
      if segment.where&.values&.any? { |value| value.is_a?(Hash) }
        raise DeclarationError, "always: where: holds plain values, a relative offset cannot apply to every query"
      end

      super(where: segment.where, scope: segment.scope)
    rescue DeclarationError => e
      raise DeclarationError, e.problems.map { |problem| problem.sub("segment :always: ", "always: ") }
    end

    def scope?
      !scope.nil?
    end

    # For the messages of the checks.
    def label
      scope? ? "always scope: :#{scope}" : "always where: #{where.keys.join(', ')}"
    end
  end
end
