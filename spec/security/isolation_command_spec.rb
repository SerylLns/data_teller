require "rails_helper"
require "open3"

# What rake data_teller:isolation prints and returns (ADR 0011 D2). In-process, so that a broken tenant filter can be stubbed.
RSpec.describe DataTeller::IsolationCheck::Command do
  let(:sentinel) { "Globex only 999999" } # in Globex's rows only: it must never be printed.

  let!(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let!(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }

  before do
    [ acme, globex ].each do |account|
      customer = account.customers.create!(name: account == globex ? sentinel : "Alice", email: "a@example.test", city: "Paris")
      account.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: Time.current)
    end
  end

  def run(env = {})
    out = StringIO.new
    status = described_class.new(env: env, out: out).call
    [ out.string, status ]
  end

  it "prints OK and the rows each tenant read, and exits 0 on a correct app" do
    output, status = run

    expect(status).to eq(0)
    expect(output).to include("DataTeller isolation check: Account #{acme.id}, #{globex.id} ·", "at most 5000 rows checked per query")
    expect(output).to match(/^  orders +[1-9]\d* \/ [1-9]\d*$/)
    expect(output).to include("warning: not proved, no chosen tenant read a row of:", "shipments")
    expect(output).to match(/^OK: no row of another tenant in \d+ queries$/)
  end

  it "prints each leak by primary key, never by value, and exits 1" do
    allow_any_instance_of(DataTeller::TenantScope).to receive(:condition_for).and_wrap_original do |original, klass, path|
      klass == Customer ? klass.arel_table[:id].not_eq(nil) : original.call(klass, path)
    end
    output, status = run

    expect(status).to eq(1)
    expect(output).to include("LEAK      customers · plain · as Account #{acme.id}: customers #{globex.customers.first.id} belongs to Account #{globex.id}")
    expect(output).to match(/^FAILED: \d+ rows of another tenant read, 0 tables read with no tenant filter$/)
    expect(output).not_to include(sentinel)
  end

  it "checks the tenants given in TENANTS, in that order" do
    output, = run("TENANTS" => "#{globex.id}, #{acme.id}")

    expect(output).to include("Account #{globex.id}, #{acme.id} ·")
  end

  it "refuses an unknown tenant, a wrong CAP and an empty database rather than passing" do
    expect(run("TENANTS" => "#{acme.id},0")).to eq([ "DataTeller: TENANTS: no Account with id 0\n", 1 ])
    expect(run("CAP" => "lots")).to eq([ "DataTeller: CAP must be a positive number of rows, got \"lots\"\n", 1 ])
    expect(run("CAP" => "0").last).to eq(1)

    allow(Account).to receive(:unscoped).and_return(Account.none)
    expect(run).to eq([ "DataTeller: no Account in this database: there is nothing to check\n", 1 ])
  end

  it "says when row security may hide a compiler bug" do
    config = Class.new(SimpleDelegator) { def row_security = true }.new(DataTeller.config)
    out = StringIO.new
    described_class.new(env: {}, out: out, config: config).call

    expect(out.string).to include("Row security is on: the database filters too")
  end

  # For real, in a separate process: the task is wired, and an empty test database is a failure, not a pass.
  it "runs as a rake task" do
    stdout, _stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, "bundle", "exec", "rake", "data_teller:isolation", chdir: Rails.root.to_s)

    expect(stdout).to include("DataTeller: no Account in this database")
    expect(status.exitstatus).to eq(1)
  end
end
