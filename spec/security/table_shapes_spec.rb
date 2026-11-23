require "rails_helper"

# Table shapes common in host apps (T31a): single table inheritance, soft-delete, a nullable tenant column, a nullable key on the
# way to the tenant. Each one adds or drops rows without anyone naming it, so each is checked on real rows and two tenants.
# The tables come from the dummy's CreateSecurityShapes migration; the classes are defined here, never in config/data_teller.
RSpec.describe "Table shapes" do
  let(:sentinel) { 999_999 } # Globex's amount on each row, and on rows that belong to no tenant: any trace of it is a leak.

  let(:acme) { Account.create!(name: "Acme", time_zone: "UTC") }
  let(:globex) { Account.create!(name: "Globex", time_zone: "UTC") }

  before do
    stub_const("SpecPayment", Class.new(ApplicationRecord) { self.table_name = "security_payments" })
    SpecPayment.belongs_to :order
    stub_const("SpecCharge", Class.new(SpecPayment))
    stub_const("SpecRefund", Class.new(SpecPayment))

    # The same rows, soft-deleted ones hidden. STI off: it reads every payment, whatever its type.
    stub_const("SpecKeptPayment", Class.new(ApplicationRecord) { self.table_name = "security_payments" })
    SpecKeptPayment.class_eval do
      self.inheritance_column = :_sti_disabled
      belongs_to :order
      default_scope { where(deleted_at: nil) }
    end

    # Three ways to reach the same payment: as any payment, as a refund (STI), as a payment that is not deleted.
    stub_const("SpecDispute", Class.new(ApplicationRecord) { self.table_name = "security_disputes" })
    SpecDispute.class_eval do
      belongs_to :payment, class_name: "SpecPayment", foreign_key: :security_payment_id, optional: true
      belongs_to :refund, class_name: "SpecRefund", foreign_key: :security_payment_id, optional: true
      belongs_to :kept_payment, class_name: "SpecKeptPayment", foreign_key: :security_payment_id, optional: true
    end

    stub_const("SpecNote", Class.new(ApplicationRecord) { self.table_name = "security_notes" })
    SpecNote.belongs_to :account, optional: true

    acme_order = acme.orders.create!(customer: acme.customers.create!(name: "Alice", email: "alice@example.test"), status: 1, total_cents: 1, ordered_at: Time.current)
    globex_order = globex.orders.create!(customer: globex.customers.create!(name: "Other", email: "other@example.test"), status: 1, total_cents: 1, ordered_at: Time.current)

    charge = SpecCharge.create!(order: acme_order, amount_cents: 5_000)
    refund = SpecRefund.create!(order: acme_order, amount_cents: -1_200)
    deleted = SpecCharge.create!(order: acme_order, amount_cents: 7_000, deleted_at: Time.current)
    [ SpecCharge, SpecRefund ].each { |type| SpecDispute.create!(payment: type.create!(order: globex_order, amount_cents: sentinel), amount_cents: sentinel) }
    SpecCharge.create!(order: globex_order, amount_cents: sentinel, deleted_at: Time.current)

    SpecDispute.create!(payment: refund, amount_cents: 10)
    SpecDispute.create!(payment: charge, amount_cents: 20)
    SpecDispute.create!(payment: deleted, amount_cents: 40)
    SpecDispute.create!(payment: nil, amount_cents: sentinel)

    SpecNote.create!(account: acme, value: 1)
    SpecNote.create!(account: globex, value: sentinel)
    SpecNote.create!(account: nil, value: sentinel)
  end

  def dataset(model, tenant_path, column: :amount_cents, dimensions: [], always: [])
    DataTeller::Dataset.new(model_name: model, roles: %i[admin], tenant_path: tenant_path, always: always,
                            dimensions: dimensions.map { |name| DataTeller::Dimension.new(name: name, group: true) },
                            metrics: [ DataTeller::Metric.new(name: :total, aggregation: :sum, column: column) ])
  end

  def rows(datasets, name, shape = {}, tenant: acme)
    registry = DataTeller::Registry.new
    datasets.each { |declared| registry.register(declared) }
    catalog = DataTeller::Catalog.new([ :admin ], registry: registry.freeze!, tenant_model_name: "Account")
    query = { "version" => 1, "intent" => "answer", "dataset" => name, "metric" => "total" }.merge(shape)

    DataTeller::ReadOnlyExecution.run(catalog.dataset(name).model_name.constantize, timeout: 5) do
      DataTeller::Compiler.new(catalog: catalog, tenant: tenant, time_zone: ActiveSupport::TimeZone["UTC"], now: Time.current).call(query).execute.rows
    end
  end

  def by_payment_amount(path) = { "group_by" => [ { "dimension" => "#{path}.amount_cents" } ] }

  describe "single table inheritance" do
    it "reads only the subclass's rows, and every row from the parent class" do
      expect(rows([ dataset("SpecRefund", %i[order account]) ], "spec_refunds")).to eq([ [ -1_200 ] ])
      expect(rows([ dataset("SpecCharge", %i[order account]) ], "spec_charges")).to eq([ [ 12_000 ] ])
      expect(rows([ dataset("SpecPayment", %i[order account]) ], "spec_payments")).to eq([ [ 10_800 ] ])
    end

    it "keeps the subclass's condition on a joined table" do
      declared = [ dataset("SpecDispute", %i[payment order account]), dataset("SpecRefund", %i[order account], dimensions: %i[amount_cents]) ]

      expect(rows(declared, "spec_disputes", by_payment_amount("refund"))).to eq([ [ -1_200, 10 ] ])
    end

    # A dispute on a charge has no refund, so a path through the refund finds no tenant for it: it is left out, never guessed.
    it "keeps the subclass's condition in the middle of a tenant_path" do
      declared = [ dataset("SpecDispute", %i[refund order account]) ]

      expect(rows(declared, "spec_disputes")).to eq([ [ 10 ] ])
      expect(rows(declared, "spec_disputes", tenant: globex)).to eq([ [ sentinel ] ])
    end
  end

  describe "soft-delete with a default_scope" do
    it "leaves deleted rows out of the dataset" do
      expect(rows([ dataset("SpecKeptPayment", %i[order account]) ], "spec_kept_payments")).to eq([ [ 3_800 ] ])
    end

    it "leaves deleted rows out of a joined table" do
      declared = [ dataset("SpecDispute", %i[payment order account]), dataset("SpecKeptPayment", %i[order account], dimensions: %i[amount_cents]) ]

      expect(rows(declared, "spec_disputes", by_payment_amount("kept_payment"))).to contain_exactly([ -1_200, 10 ], [ 5_000, 20 ])
    end

    # Who owns a row does not depend on whether its parent was deleted (TenantScope reads parents unscoped).
    it "keeps a row whose parent on the tenant_path is deleted with its tenant" do
      declared = [ dataset("SpecDispute", %i[kept_payment order account]) ]

      expect(rows(declared, "spec_disputes")).to eq([ [ 70 ] ])
      expect(rows(declared, "spec_disputes", tenant: globex)).to eq([ [ sentinel * 2 ] ])
    end
  end

  # The same soft-delete with no default_scope, as `discard` has it, or a status the app hides in its policy only (ADR 0014).
  describe "conditions always applied" do
    before do
      SpecPayment.scope :kept, -> { where(deleted_at: nil) }
      SpecPayment.scope :not_refunds, -> { where.not(type: "SpecRefund") }
    end

    let(:kept) { DataTeller::Always.new(where: { deleted_at: nil }) }

    it "leaves the rows out of the dataset, as a where: or as a scope" do
      expect(rows([ dataset("SpecPayment", %i[order account], always: [ kept ]) ], "spec_payments")).to eq([ [ 3_800 ] ])
      expect(rows([ dataset("SpecPayment", %i[order account], always: [ DataTeller::Always.new(scope: :kept) ]) ], "spec_payments")).to eq([ [ 3_800 ] ])
      expect(rows([ dataset("SpecPayment", %i[order account], always: [ kept ]) ], "spec_payments", tenant: globex)).to eq([ [ sentinel * 2 ] ])
    end

    it "applies every condition, a negation written as a scope among them" do
      both = [ kept, DataTeller::Always.new(scope: :not_refunds) ]

      expect(rows([ dataset("SpecPayment", %i[order account], always: both) ], "spec_payments")).to eq([ [ 5_000 ] ])
    end

    it "leaves the rows out of a joined table, built on that table" do
      declared = [ dataset("SpecDispute", %i[payment order account]), dataset("SpecPayment", %i[order account], dimensions: %i[amount_cents], always: [ kept ]) ]

      expect(rows(declared, "spec_disputes", by_payment_amount("payment"))).to contain_exactly([ -1_200, 10 ], [ 5_000, 20 ])
    end

    # As with a default_scope: the total keeps the dispute on a deleted payment, the breakdown through it does not (ADR 0014 D2).
    it "does not change who owns a row" do
      declared = [ dataset("SpecDispute", %i[payment order account]), dataset("SpecPayment", %i[order account], always: [ kept ]) ]

      expect(rows(declared, "spec_disputes")).to eq([ [ 70 ] ])
      expect(rows(declared, "spec_disputes", tenant: globex)).to eq([ [ sentinel * 2 ] ])
    end

    it "refuses the query when the scope no longer holds only conditions" do
      SpecPayment.scope :kept, -> { where(deleted_at: nil).limit(1) }

      expect { rows([ dataset("SpecPayment", %i[order account], always: [ DataTeller::Always.new(scope: :kept) ]) ], "spec_payments") }
        .to raise_error(DataTeller::Compiler::Refused, /scope :kept uses limit/)
    end
  end

  describe "nullable keys" do
    it "gives a row with no tenant to no tenant" do
      declared = [ dataset("SpecNote", %i[account], column: :value) ]

      expect(rows(declared, "spec_notes")).to eq([ [ 1 ] ])
      expect(rows(declared, "spec_notes", tenant: globex)).to eq([ [ sentinel ] ])
    end

    it "gives a row with no parent on the tenant_path to no tenant" do
      declared = [ dataset("SpecDispute", %i[payment order account]) ]

      expect(rows(declared, "spec_disputes")).to eq([ [ 70 ] ])
      expect(rows(declared, "spec_disputes", tenant: globex)).to eq([ [ sentinel * 2 ] ])
    end
  end
end
