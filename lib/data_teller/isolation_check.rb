module DataTeller
  # Proves tenant isolation on the integrator's own tables (ADR 0011). For each query of `probes` and each tenant, every row the
  # query reads is traced back to its owner, and any row that is not the asking tenant's is a leak. It only reads, inside a
  # read-only transaction that is always rolled back, so it can run on a copy of production. The report holds dataset names,
  # query shapes and primary keys, never a value: it ends up in CI logs.
  class IsolationCheck
    DEFAULT_CAP = 5_000

    # shape: what the query exercises, for the report. other_value: the dimension is compared to a value read from another
    # tenant's rows, filled per tenant at run time.
    Probe = Data.define(:dataset, :shape, :query, :other_value)

    # owner: the key of the tenant the row belongs to, nil for a row that belongs to no tenant.
    Leak = Data.define(:dataset, :key, :owner)

    # unlisted: tables the SQL reads that the compiler built no tenant filter for. partial: the cap was hit, so only part of the rows were checked. unkeyed: datasets with no single primary key.
    # refusal: why the query did not run (the validator's codes, a refusal reason or an error class), nil when it ran.
    Run = Data.define(:dataset, :shape, :tenant, :leaks, :unlisted, :partial, :unkeyed, :refusal) do
      def failed? = leaks.any? || unlisted.any?
    end

    # rows_read: dataset name => { tenant key => distinct rows read }, over every query: a row read by fifty queries counts once,
    # so the number is how much of the tenant's table the check covered.
    Report = Data.define(:tenants, :runs, :rows_read) do
      def failed? = runs.any?(&:failed?)
      # Each row of another tenant once, whatever the number of queries that read it.
      def leaks = runs.flat_map(&:leaks).uniq { |leak| [ leak.dataset, leak.key ] }

      # A dataset no chosen tenant read a row of proves nothing: a warning, never a pass (ADR 0011 D3).
      def not_proved(dataset_names) = dataset_names.reject { |name| rows_read[name].values.sum.positive? }
    end

    class Unprovable < Error; end

    # The union of every declared role: the tenant filter does not depend on the role, so one catalog holds everything a query can
    # reach (ADR 0011 D3).
    def self.declared_roles(registry)
      registry.datasets.flat_map do |dataset|
        members = dataset.metrics.values + dataset.dimensions.values + dataset.segments.values
        [ *dataset.roles, *members.flat_map { |member| Array(member.roles) } ]
      end.uniq
    end

    # The first two by primary key, often the oldest and fullest, and the last one, often new and nearly empty: anything an empty
    # tenant reads is a leak.
    def self.default_tenants(tenant_model)
      ordered = tenant_model.unscoped.order(tenant_model.primary_key)
      (ordered.limit(2).to_a + [ ordered.last ]).compact.uniq
    end

    # tenants: records of the tenant model, default_tenants when nil.
    def initialize(registry: DataTeller.registry, config: DataTeller.config, tenants: nil, cap: DEFAULT_CAP, now: Time.current)
      @registry = registry
      @config = config
      @tenant_model = config.tenant_model_name.constantize
      @catalog = Catalog.new(self.class.declared_roles(registry), registry: registry, tenant_model_name: config.tenant_model_name)
      @tenants = tenants || self.class.default_tenants(@tenant_model)
      @cap = cap
      @now = now
    end

    def call
      # One set of keys per dataset and tenant, filled as queries run: memory grows with the distinct rows checked, not with the
      # number of queries times the cap.
      @seen = Hash.new { |hash, name| hash[name] = Hash.new { |by_tenant, tenant| by_tenant[tenant] = Set.new } }
      runs = @tenants.each_with_index.flat_map do |tenant, index|
        other = @tenants[(index + 1) % @tenants.size] unless @tenants.one?
        probes.map { |probe| run(probe, tenant, other) }
      end

      rows_read = Hash.new { |hash, name| hash[name] = Hash.new(0) }
      @seen.each { |name, by_tenant| by_tenant.each { |tenant, keys| rows_read[name][tenant] = keys.size } }
      Report.new(tenants: @tenants.map { |tenant| key_of(tenant) }, runs: runs, rows_read: rows_read)
    end

    def dataset_names = @catalog.datasets.map { |entry| entry.name.to_s }

    # One query per declaration, the same on every run (ADR 0011 D4).
    def probes
      @catalog.datasets.flat_map do |entry|
        base = { "version" => 1, "intent" => "answer", "dataset" => entry.name.to_s, "metric" => default_metric(entry).name.to_s }
        probe = ->(shape, extra, other_value = nil) { Probe.new(dataset: entry.name.to_s, shape: shape, query: base.merge(extra), other_value: other_value) }

        [
          probe.call("plain", {}),
          *entry.fields.select(&:groupable?).map { |field| probe.call("group_by #{field.name}", "group_by" => [ group_item(field) ]) },
          *entry.segments.map { |segment| probe.call("segment #{segment.name}", "filters" => [ { "segment" => segment.name.to_s } ]) },
          *entry.metrics.reject { |metric| metric.steps.empty? }.map { |metric| probe.call("metric #{metric.name}", "metric" => metric.name.to_s) },
          *entry.fields.select(&:filterable?).map { |field| probe.call("#{field.name} = a value of another tenant", {}, field) }
        ]
      end
    end

    # As QueryRunner runs it, with the same database role and row security, so that the report is about what the app does. Also
    # CostReport's way in (ADR 0013 D4).
    def as_the_app(query, tenant, &block)
      model = @catalog.dataset(query["dataset"]).model_name.constantize
      time_zone = @config.time_zone_for(tenant) || ActiveSupport::TimeZone["UTC"]

      ReadOnlyExecution.run(model, timeout: @config.query_timeout, role: @config.database_role,
                                   tenant_id: (key_of(tenant) if @config.row_security)) do
        Compiler.new(catalog: @catalog, tenant: tenant, time_zone: time_zone, now: @now).call(query).plans.map(&block)
      end
    end

    # A value of `field` in the rows `tenant` reads, through the app's own path. Read as another tenant, it is the "another customer's
    # id" attack: a value the other tenant could really see, read back by primary key outside it. CostReport reads the tenant's own.
    def value_seen_by(field, tenant)
      # The table that holds the column: the last one joined for a path (customer.city), the dataset's own otherwise.
      owner = field.via.last ? @catalog.dataset(field.via.last.name) : @catalog.datasets.find { |entry| entry.model_name == field.model_name }
      return nil unless owner

      query = { "version" => 1, "intent" => "answer", "dataset" => owner.name.to_s, "metric" => default_metric(owner).name.to_s }
      keys = as_the_app(query, tenant) { |plan| plan.row_keys(cap: 50).rows.map(&:last) }.first
      model = field.model

      ReadOnlyExecution.run(model, timeout: @config.query_timeout) do
        model.unscoped.where(model.primary_key => keys).where.not(field.dimension.column => nil).pick(field.dimension.column)
      end
    rescue Compiler::Refused
      nil
    end

    private

    def default_metric(entry) = entry.metrics.find { |metric| metric.name == :count } || entry.metrics.first

    def group_item(field)
      field.date? ? { "dimension" => field.name.to_s, "granularity" => "month" } : { "dimension" => field.name.to_s }
    end

    def key_of(record) = record.public_send(record.class.primary_key)

    def run(probe, tenant, other)
      query = probe.query
      if probe.other_value
        value = other && value_seen_by(probe.other_value, other)
        return outcome(probe, tenant, refusal: other ? :no_value_in_another_tenant : :one_tenant_only) if value.nil?

        query = query.merge("filters" => [ { "dimension" => probe.other_value.name.to_s, "op" => "eq", "value" => value } ])
      end

      read = as_the_app(query, tenant) { |plan| [ plan.touched, plan.tables_read, plan.row_keys(cap: @cap) ] }
      check(probe, tenant, read)
    rescue Compiler::Refused => e
      # lookup_required says more than unsupported_query: which rule refused, so the integrator knows what was not tried.
      outcome(probe, tenant, refusal: e.codes.any? ? e.codes.join("+") : e.reason)
    rescue ActiveRecord::StatementInvalid, ReadOnlyExecution::OutOfTime, Unprovable => e
      # The class only: a database message can hold values.
      outcome(probe, tenant, refusal: e.class.name)
    end

    def check(probe, tenant, read)
      leaks = []
      unlisted = []
      partial = false
      unkeyed = []

      read.each do |touched, tables_read, keys|
        unlisted |= tables_read - touched.map { |dataset| dataset.model_name.constantize.table_name }
        partial ||= keys.truncated
        unkeyed |= keys.unkeyed.map { |dataset| dataset.name.to_s }

        keys.datasets.each_with_index do |dataset, column|
          ids = keys.rows.map { |row| row[column] }.uniq
          @seen[dataset.name.to_s][key_of(tenant)].merge(ids)
          owners(dataset, ids).each do |id, owner|
            leaks << Leak.new(dataset: dataset.name.to_s, key: id, owner: owner) unless owner == key_of(tenant)
          end
        end
      end

      Run.new(dataset: probe.dataset, shape: probe.shape, tenant: key_of(tenant), leaks: leaks.uniq,
              unlisted: unlisted, partial: partial, unkeyed: unkeyed, refusal: nil)
    end

    # The oracle (ADR 0011 D1): who owns each row, found apart from the compiler. TenantScope filters with SQL sub-queries; this
    # follows the tenant_path's foreign keys one table at a time, by batches, and matches them in Ruby. It reads parents unscoped,
    # as TenantScope does: who owns a row does not depend on a soft-delete. STI keeps its type condition either way.
    def owners(dataset, ids)
      return {} if ids.empty?

      klass = dataset.model_name.constantize
      return ids.to_h { |id| [ id, id ] } if dataset.tenant_path.nil?

      ReadOnlyExecution.run(klass, timeout: @config.query_timeout) do
        reached = ids.to_h { |id| [ id, id ] }
        lookup = klass.primary_key

        dataset.tenant_path.each do |step|
          reflection = klass.reflect_on_association(step)
          unless reflection&.belongs_to? && !reflection.polymorphic?
            raise Unprovable, "#{klass.name}.#{step} is not a belongs_to association"
          end

          following = reached.values.compact.uniq.each_slice(1_000).each_with_object({}) do |slice, found|
            found.merge!(klass.unscoped.where(lookup => slice).pluck(lookup, reflection.foreign_key).to_h)
          end
          reached = reached.transform_values { |value| following[value] }
          klass = reflection.klass
          lookup = reflection.association_primary_key
        end
        # The last key read is the tenant's `lookup` column: it is the owner only if that column is the one the report keys on.
        raise Unprovable, "#{dataset.name}'s tenant_path ends on #{lookup}, not the primary key" unless lookup == @tenant_model.primary_key

        reached
      end
    end

    def outcome(probe, tenant, refusal:)
      Run.new(dataset: probe.dataset, shape: probe.shape, tenant: key_of(tenant), leaks: [], unlisted: [], partial: false,
              unkeyed: [], refusal: refusal)
    end
  end
end
