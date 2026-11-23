require "rails_helper"
require "open3"

# What rake data_teller:costs prints (ADR 0013 D4): the kit's queries, estimated then run, sorted by cost.
RSpec.describe DataTeller::CostReport::Command do
  let(:sentinel) { "Sentinelville" } # a value the filter probes read and use: it must never be printed.
  let!(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }

  before do
    customer = acme.customers.create!(name: "Alice", email: "a@example.test", city: sentinel)
    3.times { acme.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: Time.current) }
  end

  def run(env = {}, config: DataTeller.config)
    out = StringIO.new
    status = described_class.new(env: env, out: out, config: config).call
    [ out.string, status ]
  end

  def with_max_query_cost(value) = Class.new(SimpleDelegator) { define_method(:max_query_cost) { value } }.new(DataTeller.config)

  # cost, ms, the query: the measured lines of the table, as printed.
  def table(output) = output.lines.grep(/\A +\d+\.\d\d +(\d+\.\d\d|> \d+)  \S/).map { |line| line.split(/ {2,}/).map(&:strip).reject(&:empty?) }

  it "prints each query's estimated cost and real duration, sorted by cost, and exits 0" do
    output, status = run

    expect(status).to eq(0)
    expect(output).to include("DataTeller query costs: Account #{acme.id} ·", "max_query_cost: not set · query_timeout: 5 s")
    rows = table(output)
    expect(rows.size).to be > 50
    expect(rows.map { |row| row[0].to_f }).to eq(rows.map { |row| row[0].to_f }.sort)
    expect(rows).to include([ a_string_matching(/\A\d+\.\d\d\z/), a_string_matching(/\A\d+\.\d\d\z/), "orders · plain · as Account #{acme.id}" ])
    expect(output).to include("customers · city = one of its values · as Account #{acme.id}")
  end

  it "says why a query was not measured, by the rule that refused it" do
    output, = run

    expect(output).to match(/^not measured: \d+ queries \(/)
    expect(output).to include("  customers · name = one of its values: lookup_required")
  end

  it "never prints a value, even the ones its filters use" do
    output, = run

    expect(output).not_to include(sentinel, "Alice", "a@example.test")
  end

  it "marks where the current max_query_cost falls" do
    costs = table(run.first).map { |row| row[0].to_f }.uniq
    threshold = costs[costs.size / 2]
    output, = run(config: with_max_query_cost(threshold))

    lines = output.lines.map(&:chomp)
    marker = lines.index("  ---- max_query_cost #{threshold}: refused from here ----")
    expect(marker).not_to be_nil
    expect(table(lines[...marker].join("\n")).map { |row| row[0].to_f }).to all(be <= threshold)
    expect(table(lines[marker..].join("\n")).map { |row| row[0].to_f }).to all(be > threshold)
  end

  # The estimate is taken apart, before the run: the query the budget stops is the one whose cost the integrator needs most.
  it "keeps the cost of a query the time budget stopped" do
    allow(DataTeller::QueryCost).to receive(:measure).and_raise(ActiveRecord::QueryCanceled)

    rows = table(run.first)
    expect(rows).not_to be_empty
    expect(rows.map { |row| row[1] }).to all(eq("> 5000"))
  end

  it "runs every statement inside the app's read-only transaction" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    run
    ActiveSupport::Notifications.unsubscribe(subscriber)

    analyzed = statements.index { |sql| sql.start_with?("EXPLAIN (ANALYZE, TIMING OFF, FORMAT JSON) SELECT") }
    expect(analyzed).not_to be_nil
    expect(statements[...analyzed].rindex("SET TRANSACTION READ ONLY")).to be > statements[...analyzed].rindex { |sql| sql.start_with?("EXPLAIN (FORMAT JSON)") }
  end

  it "refuses an unknown tenant and an empty database, as the kit does" do
    expect(run({ "TENANTS" => "0" })).to eq([ "DataTeller: TENANTS: no Account with id 0\n", 1 ])

    allow(Account).to receive(:unscoped).and_return(Account.none)
    expect(run).to eq([ "DataTeller: no Account in this database: there is nothing to measure\n", 1 ])
  end

  it "runs as a rake task" do
    stdout, _stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, "bundle", "exec", "rake", "data_teller:costs", chdir: Rails.root.to_s)

    expect(stdout).to include("DataTeller: no Account in this database")
    expect(status.exitstatus).to eq(1)
  end
end
