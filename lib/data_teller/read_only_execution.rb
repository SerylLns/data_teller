module DataTeller
  # Everything that touches the database for a query runs in here, compilation included, since calling a scope runs its code.
  # The database enforces it: a write is an error whatever the code tries, raw SQL included. Code that does something else
  # than SQL, an HTTP call in a scope for instance, is out of reach.
  module ReadOnlyExecution
    # Always rolled back. Nothing was written anyway, and inside a host transaction this is a savepoint: releasing it would
    # keep the read-only mode and the timeout for the rest of the host's transaction.
    #
    # role: the Postgres role to run as, which can only read the declared columns (T37). The rollback restores the app's own
    # user, a savepoint's included. Code in a scope can still RESET ROLE: like the timeout, this guards against a bug in the gem,
    # not against the host's code.
    #
    # tenant_id: the key the row-level security policies compare to (T39, ADR 0005 D7). Local to the transaction, so it ends with
    # it; a bound value, so it is never part of the statement.
    #
    # timeout: seconds for everything in the block, however many statements it sends (ADR 0013 D2). Postgres times each statement,
    # so a plan calls before_statement to give the next one the time left.
    def self.run(model, timeout:, role: nil, tenant_id: nil)
      result = nil
      deadline = clock + timeout
      outer = ActiveSupport::IsolatedExecutionState[BUDGET]

      model.transaction(requires_new: true) do
        model.with_connection do |connection|
          connection.execute("SET TRANSACTION READ ONLY")
          # Postgres lets a top-level transaction go back to read-write until its first query, and a SET does not count as one.
          # Without this, code in a scope could undo the guard. Before the timeout, which must not cancel it.
          connection.select_value("SELECT 1")
          connection.execute("SET LOCAL ROLE #{connection.quote_column_name(role)}") if role
          connection.select_value("SELECT set_config('#{TENANT_SETTING}', $1, true)", "DataTeller", [ tenant_bind(tenant_id) ]) if tenant_id
          # Code in a scope can still change this one. It is the host's own code, and nothing in a transaction can stop that.
          connection.execute("SET LOCAL statement_timeout = #{(timeout * 1000).ceil}")
        end
        ActiveSupport::IsolatedExecutionState[BUDGET] = Budget.new(model: model, deadline: deadline)
        result = yield
        raise ActiveRecord::Rollback
      end

      result
    ensure
      # A run inside another one is a savepoint: its rollback restores the outer timeout, and this the outer deadline.
      ActiveSupport::IsolatedExecutionState[BUDGET] = outer
    end

    # The time left goes to the next statement; with none left it is not sent. Outside run there is no budget and nothing to do: a
    # plan read by a spec or a console runs with no guard at all.
    def self.before_statement
      budget = ActiveSupport::IsolatedExecutionState[BUDGET]
      return unless budget

      left = budget.deadline - clock
      raise OutOfTime, "the question's time budget is spent" unless left.positive?

      budget.model.with_connection { |connection| connection.execute("SET LOCAL statement_timeout = #{(left * 1000).ceil}") }
    end

    # Monotonic: a clock set back or forward must not give a question more time, or none.
    def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    class OutOfTime < Error; end

    Budget = Data.define(:model, :deadline)
    BUDGET = :data_teller_query_budget

    TENANT_SETTING = "data_teller.tenant_id".freeze

    def self.tenant_bind(value)
      ActiveRecord::Relation::QueryAttribute.new("tenant_id", value.to_s, ActiveRecord::Type::String.new)
    end
    private_class_method :tenant_bind
  end
end
