require "json"

module DataTeller
  # The planner's estimate for a whole question (ADR 0013 D3): the sum of the Total Cost of each statement's plan. EXPLAIN without
  # ANALYZE plans and runs nothing, so a refused question has read no row. Called inside ReadOnlyExecution.run, under the same role
  # and row security as the statements themselves: the plan estimated is the plan that would run.
  module QueryCost
    # statements: SQL as Plan#statements gives it. The values are in the text, quoted by Rails as with prepared_statements off:
    # Rails keeps the methods that would give the SQL and its binds apart private. They were cast by the compiler, and the planner
    # estimates a literal the way it estimates a bound value in a custom plan.
    def self.estimate(model, statements, recorder: nil)
      statements.sum { |sql| total_cost(model, "EXPLAIN (FORMAT JSON) #{sql}", recorder) }
    end

    def self.total_cost(model, explain, recorder)
      recorder&.call(explain)
      # Planning is a statement too, with the time left.
      ReadOnlyExecution.before_statement
      plan = model.with_connection { |connection| connection.select_value(explain, "DataTeller") }
      plan = JSON.parse(plan) if plan.is_a?(String)
      plan.first.fetch("Plan").fetch("Total Cost")
    end
    private_class_method :total_cost
  end
end
