require "rails_helper"

# The kit itself (ADR 0011): a clean app must pass with no false alarm, and a broken tenant filter must be caught. The breakages
# are stubs on purpose: the compiler is right, so the only way to see the kit catch a leak is to make the compiler wrong.
RSpec.describe DataTeller::IsolationCheck do
  let(:sentinel) { "Globex only 999999" } # in Globex's rows only: it must never appear in a report.

  let!(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let!(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }
  let!(:initech) { Account.create!(name: "Initech", time_zone: "UTC") } # last by primary key, and empty

  before do
    [ acme, acme, globex ].each_with_index do |account, index|
      customer = account.customers.create!(name: account == globex ? sentinel : "Alice #{index}", email: "c#{index}@example.test", city: account == globex ? sentinel : "Paris")
      account.orders.create!(customer: customer, status: 1, total_cents: 100, ordered_at: Time.current)
    end
  end

  def check(**options) = described_class.new(**options).call

  # Lets one model's rows through for every tenant, the way a wrong tenant_path or a widening scope would.
  def break_tenant_filter_of(model)
    allow_any_instance_of(DataTeller::TenantScope).to receive(:condition_for).and_wrap_original do |original, klass, path|
      klass == model ? klass.arel_table[klass.primary_key].not_eq(nil) : original.call(klass, path)
    end
  end

  it "chooses the first two tenants by primary key and the last one" do
    expect(check.tenants).to eq([ acme.id, globex.id, initech.id ])
  end

  # Dozens of queries read Acme's two orders: the count is the rows covered, each once, not the reads.
  it "passes on a correct app, and counts the distinct rows each tenant read" do
    report = check

    expect(report).not_to be_failed
    expect(report.rows_read["orders"].values_at(acme.id, globex.id, initech.id)).to eq([ 2, 1, 0 ])
  end

  it "runs one query per declaration: plain, each groupable dimension, segment, metric path and filter by another tenant's value" do
    shapes = described_class.new.probes.select { |probe| probe.dataset == "orders" }.map(&:shape)

    expect(shapes).to include("plain", "group_by status", "group_by customer.name", "segment paid", "status = a value of another tenant",
                              "customer.city = a value of another tenant")
  end

  # customer.name is matched through a lookup, which a probe cannot write yet: the report says which rule refused it.
  it "says why a query was not tried with the validator's own code" do
    run = check.runs.find { |one| one.dataset == "orders" && one.shape == "customer.name = a value of another tenant" }

    expect(run.refusal).to eq("lookup_required")
  end

  it "reports a dataset no chosen tenant read a row of as not proved" do
    report = check

    expect(report.not_proved(described_class.new.dataset_names)).to include("shipments")
    expect(report.not_proved(described_class.new.dataset_names)).not_to include("orders", "customers")
  end

  it "catches a table whose tenant filter lets every tenant's rows through" do
    break_tenant_filter_of(Customer)
    report = check

    expect(report).to be_failed
    # Every customer leaks to some other tenant, and each is reported once however many queries read it.
    expect(report.leaks.map { |leak| [ leak.dataset, leak.key ] }).to match_array(Customer.pluck(:id).map { |id| [ "customers", id ] })
    expect(report.leaks).to include(have_attributes(key: globex.customers.first.id, owner: globex.id))
    expect(report.runs.select(&:failed?).map(&:tenant)).to include(initech.id)
  end

  # An Acme order pointing at a Globex customer: a correct compiler drops it with the join's own filter. Broken, that filter lets
  # Globex's customer through, and only the joined table leaks.
  it "catches a leak on a joined table" do
    acme.orders.create!(customer: globex.customers.first, status: 1, total_cents: 100, ordered_at: Time.current)
    expect(check).not_to be_failed

    break_tenant_filter_of(Customer)
    run = check.runs.find { |one| one.dataset == "orders" && one.shape == "group_by customer.name" && one.tenant == acme.id }

    expect(run.leaks).to contain_exactly(have_attributes(dataset: "customers", owner: globex.id))
  end

  # ADR 0016: a list on each listable dataset, then one per column reached through a path, every row of the list traced to its owner.
  describe "lists" do
    it "probes the default list and each column a path reaches" do
      shapes = described_class.new.probes.select { |probe| probe.dataset == "orders" }.map(&:shape)

      expect(shapes).to include("list", "list customer.city", "list customer.name")
      expect(shapes.grep(/\Alist/).size).to eq(1 + DataTeller::Catalog.for(:admin).dataset(:orders).fields.count { |field| field.steps.any? })
    end

    it "passes on a correct app, and catches a leak on a table a list joins" do
      acme.orders.create!(customer: globex.customers.first, status: 1, total_cents: 100, ordered_at: Time.current)
      run = ->(report) { report.runs.find { |one| one.dataset == "orders" && one.shape == "list customer.city" && one.tenant == acme.id } }
      expect(run.call(check)).to have_attributes(failed?: false, refusal: nil)

      break_tenant_filter_of(Customer)
      expect(run.call(check).leaks).to contain_exactly(have_attributes(dataset: "customers", owner: globex.id))
    end
  end

  it "fails on a table the SQL reads that the compiler built no tenant filter for" do
    allow_any_instance_of(DataTeller::Plan).to receive(:touched).and_wrap_original do |original|
      original.call.reject { |dataset| dataset.name == :customers }
    end
    run = check.runs.find { |one| one.dataset == "orders" && one.shape == "group_by customer.name" && one.tenant == acme.id }

    expect(run).to be_failed
    expect(run.unlisted).to eq([ "customers" ])
  end

  it "says when the cap stopped it" do
    run = check(cap: 1).runs.find { |one| one.dataset == "orders" && one.shape == "plain" && one.tenant == acme.id }

    expect(run).to have_attributes(partial: true, refusal: nil)
  end

  it "never puts a value in the report" do
    break_tenant_filter_of(Customer)

    expect(check.inspect).not_to include(sentinel)
  end

  describe "a soft-deleted parent on the tenant_path" do
    before do
      stub_const("SpecPayment", Class.new(ApplicationRecord) { self.table_name = "security_payments" })
      SpecPayment.class_eval do
        self.inheritance_column = :_sti_disabled
        belongs_to :order
        default_scope { where(deleted_at: nil) }
      end
      stub_const("SpecDispute", Class.new(ApplicationRecord) { self.table_name = "security_disputes" })
      SpecDispute.belongs_to :payment, class_name: "SpecPayment", foreign_key: :security_payment_id

      payment = SpecPayment.create!(order: acme.orders.first, amount_cents: 1, type: "SpecPayment", deleted_at: Time.current)
      SpecDispute.create!(payment: payment, amount_cents: 1)
    end

    # The compiler keeps the dispute with Acme (TenantScope reads parents unscoped); the oracle must agree, not cry leak.
    it "gives the row to its tenant, as the compiler does" do
      registry = DataTeller::Registry.new
      registry.register(DataTeller::Dataset.new(model_name: "SpecDispute", roles: %i[admin], tenant_path: %i[payment order account],
                                                metrics: [ DataTeller::Metric.new(name: :count, aggregation: :count) ]))
      report = check(registry: registry.freeze!)

      expect(report).not_to be_failed
      expect(report.rows_read["spec_disputes"][acme.id]).to eq(1)
    end
  end
end
