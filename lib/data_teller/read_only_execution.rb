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
    def self.run(model, timeout:, role: nil)
      result = nil

      model.transaction(requires_new: true) do
        model.with_connection do |connection|
          connection.execute("SET TRANSACTION READ ONLY")
          # Postgres lets a top-level transaction go back to read-write until its first query, and a SET does not count as one.
          # Without this, code in a scope could undo the guard. Before the timeout, which must not cancel it.
          connection.select_value("SELECT 1")
          connection.execute("SET LOCAL ROLE #{connection.quote_column_name(role)}") if role
          # Code in a scope can still change this one. It is the host's own code, and nothing in a transaction can stop that.
          connection.execute("SET LOCAL statement_timeout = #{(timeout * 1000).ceil}")
        end
        result = yield
        raise ActiveRecord::Rollback
      end

      result
    end
  end
end
