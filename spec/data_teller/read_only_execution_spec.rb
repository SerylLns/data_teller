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
