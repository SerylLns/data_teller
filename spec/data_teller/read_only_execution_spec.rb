require "rails_helper"

RSpec.describe DataTeller::ReadOnlyExecution do
  let(:account) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:customer) { account.customers.create!(name: "Alice", email: "alice@example.test") }
  let!(:order) { account.orders.create!(customer: customer, status: :paid, total_cents: 100, ordered_at: Time.current) }

  def guarded(timeout: 5, &block) = described_class.run(Order, timeout: timeout, &block)
  def setting(name) = Order.with_connection { |connection| connection.select_value("SHOW #{name}") }

  it "returns what the block returns" do
    expect(guarded { Order.count }).to eq(1)
  end

  describe "writes" do
    {
      "update_all" => -> { Order.update_all(total_cents: 0) },
      "delete_all" => -> { Order.delete_all },
      "create" => -> { Account.create!(name: "New", time_zone: "UTC") },
      "raw SQL" => -> { Order.with_connection { |c| c.execute("UPDATE orders SET total_cents = 0") } },
      "DDL" => -> { Order.with_connection { |c| c.execute("CREATE TABLE spec_should_not_exist (id integer)") } },
      "a CTE that writes" => -> { Order.with_connection { |c| c.execute("WITH gone AS (DELETE FROM orders RETURNING id) SELECT COUNT(*) FROM gone") } }
    }.each do |label, write|
      it "are refused by the database: #{label}" do
        expect { guarded(&write) }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
        expect(order.reload.total_cents).to eq(100)
      end
    end

    it "cannot be switched back on from inside" do
      expect { guarded { Order.with_connection { |c| c.execute("SET TRANSACTION READ WRITE") } } }
        .to raise_error(ActiveRecord::StatementInvalid, /read-write/)
    end
  end

  describe "the statement timeout" do
    it "cancels a slow query" do
      slow = -> { Order.with_connection { |c| c.execute("SELECT pg_sleep(2)") } }

      expect { guarded(timeout: 0.05, &slow) }.to raise_error(ActiveRecord::QueryCanceled)
    end

    it "accepts a query under the limit" do
      expect(guarded(timeout: 2) { Order.count }).to eq(1)
    end
  end

  # T37: the role reads the declared columns only. Created inside the spec's transaction, so it is gone afterwards.
  describe "with a database role" do
    let(:role) { "data_teller_spec_reader" }

    before do
      Order.with_connection do |connection|
        connection.execute("CREATE ROLE #{role} NOLOGIN")
        connection.execute("GRANT SELECT (id, total_cents) ON orders TO #{role}")
      end
    end

    def current_user = Order.with_connection { |connection| connection.select_value("SELECT current_user") }

    it "runs the block as that role, and gives the connection back to the app's user" do
      app_user = current_user

      expect(described_class.run(Order, timeout: 5, role: role) { current_user }).to eq(role)
      expect(current_user).to eq(app_user)
    end

    it "reads what the role was granted, and nothing else" do
      expect(described_class.run(Order, timeout: 5, role: role) { Order.sum(:total_cents) }).to eq(100)
      expect { described_class.run(Order, timeout: 5, role: role) { Order.pluck(:status) } }
        .to raise_error(ActiveRecord::StatementInvalid, /permission denied/)
    end

    it "gives the connection back after a refusal too" do
      app_user = current_user

      expect { described_class.run(Order, timeout: 5, role: role) { Customer.pluck(:email) } }.to raise_error(ActiveRecord::StatementInvalid)
      expect(current_user).to eq(app_user)
    end

    it "is quoted, whatever it holds" do
      expect { described_class.run(Order, timeout: 5, role: %(x"; RESET ROLE; --)) { nil } }
        .to raise_error(ActiveRecord::StatementInvalid, /does not exist/)
    end
  end

  # T39: what the row policies compare to. Local to the transaction, and bound: a quote in it is a character, nothing more.
  describe "with a tenant id" do
    def tenant_setting = Order.with_connection { |connection| connection.select_value("SELECT current_setting('data_teller.tenant_id', true)") }

    it "sets it for the block only" do
      expect(described_class.run(Order, timeout: 5, tenant_id: 42) { tenant_setting }).to eq("42")
      expect(tenant_setting.to_s).to eq("")
    end

    it "keeps it a value" do
      expect(described_class.run(Order, timeout: 5, tenant_id: "1'); RESET ROLE; --") { tenant_setting }).to eq("1'); RESET ROLE; --")
    end
  end

  # The host app may call this inside its own transaction: nothing must leak out of the guard, and a failure must not poison it.
  describe "inside a host transaction" do
    it "leaves it writable, with its settings" do
      timeout_before = setting("statement_timeout")

      guarded(timeout: 1) { Order.count }

      expect(setting("transaction_read_only")).to eq("off")
      expect(setting("statement_timeout")).to eq(timeout_before)
      expect { order.update!(total_cents: 200) }.not_to raise_error
    end

    it "leaves it usable after a failure" do
      expect { guarded { Order.update_all(total_cents: 0) } }.to raise_error(ActiveRecord::StatementInvalid)

      expect(setting("transaction_read_only")).to eq("off")
      expect { order.update!(total_cents: 300) }.not_to raise_error
    end

    it "leaves it usable after a timeout" do
      expect { guarded(timeout: 0.05) { Order.with_connection { |c| c.execute("SELECT pg_sleep(2)") } } }.to raise_error(ActiveRecord::QueryCanceled)

      expect { order.update!(total_cents: 400) }.not_to raise_error
    end
  end
end

# As in production. With transactional fixtures the guard is a savepoint, and Postgres then refuses to go back to read-write on its
# own: a spec inside a transaction would pass with the guard broken. Nothing here writes data; the one role created is dropped.
RSpec.describe DataTeller::ReadOnlyExecution, "outside of any transaction" do
  self.use_transactional_tests = false

  def guarded(timeout: 5, &block) = described_class.run(Account, timeout: timeout, &block)
  def execute(sql) = Account.with_connection { |connection| connection.execute(sql) }

  it "runs in a real transaction, not a savepoint" do
    expect(guarded { Account.with_connection(&:open_transactions) }).to eq(1)
  end

  it "cannot be switched back to read-write from inside" do
    expect { guarded { execute("SET TRANSACTION READ WRITE") } }.to raise_error(ActiveRecord::StatementInvalid, /read-write/)
  end

  it "stays read-only for a write from a scope, as the first thing it does" do
    expect { guarded { Account.update_all(name: "Overwritten") } }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
  end

  # Read from the statement: a query under a 1ms limit may or may not be cancelled.
  it "keeps a limit for the shortest timeout accepted" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

    begin
      guarded(timeout: DataTeller::Configuration::MIN_STATEMENT_TIMEOUT) { nil }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    expect(statements).to include("SET LOCAL statement_timeout = 1")
  end

  # A top-level transaction ends with a ROLLBACK, not a savepoint's: SET LOCAL ROLE must not outlive it on a pooled connection.
  it "gives the connection back to the app's user" do
    app_user = Account.with_connection { |c| c.select_value("SELECT current_user") }
    execute("CREATE ROLE data_teller_spec_outside NOLOGIN")

    begin
      expect(described_class.run(Account, timeout: 5, role: "data_teller_spec_outside") { Account.with_connection { |c| c.select_value("SELECT current_user") } })
        .to eq("data_teller_spec_outside")
      expect(Account.with_connection { |c| c.select_value("SELECT current_user") }).to eq(app_user)
    ensure
      execute("DROP ROLE data_teller_spec_outside")
    end
  end

  it "leaves the connection as it was" do
    guarded { Account.count }

    expect(Account.with_connection { |c| c.select_value("SHOW transaction_read_only") }).to eq("off")
    expect(Account.with_connection { |c| c.select_value("SHOW statement_timeout") }).not_to eq("5s")
  end
end
