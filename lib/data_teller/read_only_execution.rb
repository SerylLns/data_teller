module DataTeller
  # Everything that touches the database for a query runs in here, compilation included, since calling a scope runs its code.
  # The database enforces it: a write is an error whatever the code tries, raw SQL included. Code that does something else
  # than SQL, an HTTP call in a scope for instance, is out of reach.
  module ReadOnlyExecution
    # Always rolled back. Nothing was written anyway, and inside a host transaction this is a savepoint: releasing it would
    # keep the read-only mode and the timeout for the rest of the host's transaction.
    def self.run(model, timeout:)
      result = nil

      model.transaction(requires_new: true) do
        model.with_connection do |connection|
          connection.execute("SET TRANSACTION READ ONLY")
          connection.execute("SET LOCAL statement_timeout = #{(timeout * 1000).to_i}")
        end
        result = yield
        raise ActiveRecord::Rollback
      end

      result
    end
  end
end
