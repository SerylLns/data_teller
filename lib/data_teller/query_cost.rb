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
      statements.sum { |sql| explain(model, "EXPLAIN (FORMAT JSON) #{sql}", recorder).fetch("Plan").fetch("Total Cost") }
    end

    # Milliseconds, planning included, for rake data_teller:costs only (ADR 0013 D4): ANALYZE runs the statements for real. TIMING OFF
    # times the whole statement, not each node of its plan, which would slow it down by the measuring itself. The rows stay in the
    # database: only the plan comes back.
    def self.measure(model, statements)
      statements.sum do |sql|
        plan = explain(model, "EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) #{sql}", nil)
        plan.fetch("Planning Time") + plan.fetch("Execution Time")
      end
    end

    def self.explain(model, explain, recorder)
      recorder&.call(explain)
      # Planning is a statement too, with the time left.
      ReadOnlyExecution.before_statement
      plan = model.with_connection { |connection| connection.select_value(explain, "DataTeller") }
      plan = JSON.parse(plan) if plan.is_a?(String)
      plan.first
    end
    private_class_method :explain
  end
end
