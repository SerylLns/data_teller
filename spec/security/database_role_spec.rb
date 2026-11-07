require "rails_helper"

# T37: every query the declarations allow runs under a role that reads the declared columns only, with the answer it gives
# without the role. A column missing from ReaderGrants refuses legitimate queries; this is where that shows. The queries are
# generated from the admin's catalog, so a declaration added to the dummy app is covered without editing this file.
RSpec.describe "Queries under the database role" do
  include ActiveSupport::Testing::TimeHelpers

  let(:role) { "data_teller_spec_reader" }
  let(:user_class) { Struct.new(:account, :roles) }
  let(:acme) { Account.create!(name: "Acme", time_zone: "Europe/Paris") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let(:admin) { user_class.new(acme, [ :admin ]) }
  let(:catalog) { DataTeller::Catalog.for(:admin) }

  before do
    travel_to(Time.utc(2026, 11, 4, 12))
    [ [ acme, "Paris" ], [ acme, "Lyon" ], [ globex, "Paris" ] ].each_with_index do |(account, city), index|
      customer = account.customers.create!(name: "C#{index}", email: "c#{index}@example.test", city: city)
      [ [ :paid, 1000, 2 ], [ :shipped, 3000, 40 ] ].each do |status, total, days|
        account.orders.create!(customer: customer, status: status, total_cents: total + index, ordered_at: days.days.ago, ship_on: Date.current)
      end
    end
  end

  after { travel_back }

  def execute(sql) = ActiveRecord::Base.with_connection { |connection| connection.execute(sql) }

  def grant_as_printed
    member = ActiveRecord::Base.with_connection { |connection| connection.select_value("SELECT current_user") }
    execute(DataTeller::ReaderGrants.new(registry: DataTeller.registry, tenant_model_name: "Account").sql(role: role, member: member))
  end

  def run_as(database_role, query)
    config = DataTeller::Loader.capture do
      DataTeller.configure do |c|
        c.tenant do
          model Account
          resolve { |user| user.account }
          time_zone(&:time_zone)
        end
        c.roles { |user| user.roles }
        c.database_role = database_role
      end
    end.config
    allow(DataTeller).to receive(:config).and_return(config)

    DataTeller::QueryRunner.call(query, user: admin, trace: true)
  end

  def answer(dataset, metric, **rest)
    { "version" => 1, "intent" => "answer", "dataset" => dataset.to_s, "metric" => metric.to_s }.merge(rest.transform_keys(&:to_s))
  end

  # Each metric alone and by each groupable field, each filterable field, each date as a period and in a comparison, each segment.
  def every_query
    catalog.datasets.flat_map do |entry|
      count = entry.metrics.first.name
      dates = entry.fields.select(&:period?)
      [
        *entry.metrics.map { |metric| answer(entry.name, metric.name) },
        *entry.metrics.product(entry.fields.select(&:groupable?)).map do |metric, field|
          answer(entry.name, metric.name, group_by: [ { "dimension" => field.name.to_s, "granularity" => ("month" if field.date?) }.compact ])
        end,
        *entry.fields.select(&:filterable?).map { |field| answer(entry.name, count, filters: [ { "dimension" => field.name.to_s, "op" => "is_not_null" } ]) },
        *entry.segments.map { |segment| answer(entry.name, count, filters: [ { "segment" => segment.name.to_s } ]) },
        *dates.map { |field| answer(entry.name, count, period: { "dimension" => field.name.to_s, "range" => { "relative" => "last_month" } }) },
        *dates.map { |field| answer(entry.name, count, period: { "dimension" => field.name.to_s, "range" => { "relative" => "last_month" } }, compare: "previous_period") }
      ]
    end
  end

  it "covers every kind of query, on every dataset" do
    queries = every_query

    expect(queries.size).to be > 30
    expect(queries.map { |query| query["dataset"] }.uniq).to match_array(catalog.datasets.map { |entry| entry.name.to_s })
    expect(queries.flat_map { |query| Array(query["group_by"]).map { |item| item["dimension"] } }).to include("customer.name")
    expect(queries.flat_map { |query| Array(query["filters"]).map { |item| item["dimension"] } }).to include("customer.city")
    expect(queries).to include(a_hash_including("filters" => [ { "segment" => "paid" } ]), a_hash_including("compare" => "previous_period"))
  end

  it "answers every one of them as the app's own user does" do
    grant_as_printed

    every_query.each do |query|
      without = run_as(nil, query)
      with = run_as(role, query)

      expect(without.status).to eq(:answered), query.inspect
      expect(with.status).to eq(:answered), "#{query.inspect} refused under the role: #{with.refusal&.reason}"
      expect(with.result).to eq(without.result), query.inspect
    end
  end

  it "really runs them as the role" do
    grant_as_printed
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| seen << payload[:sql] }

    outcome = run_as(role, answer(:orders, :revenue, group_by: [ { "dimension" => "customer.name" } ]))

    expect(outcome.status).to eq(:answered)
    expect(seen).to include(%(SET LOCAL ROLE "#{role}"))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # What the role is for: the day the validator or the compiler lets a column through, the database still says no.
  it "stops a column nobody declared, even when the gem's own checks are bypassed" do
    grant_as_printed

    leaked = lambda do
      DataTeller::ReadOnlyExecution.run(Customer, timeout: 5, role: role) { Customer.where(account: acme).pluck(:email) }
    end

    expect { leaked.call }.to raise_error(ActiveRecord::StatementInvalid, /permission denied for table customers/)
  end

  it "refuses a query whose column the role lost, and the trace says it stopped at execution" do
    grant_as_printed
    execute("REVOKE SELECT (total_cents) ON orders FROM #{role}")
    allow(Rails.logger).to receive(:error)

    outcome = run_as(role, answer(:orders, :revenue))

    expect(outcome.refusal.reason).to eq(:unsupported_query)
    expect(outcome.trace.stage).to eq(:execution)
    expect(Rails.logger).to have_received(:error).with(a_string_including("PG::InsufficientPrivilege"))
  end
end
