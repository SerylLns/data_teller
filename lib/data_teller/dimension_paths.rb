module DataTeller
  # The datasets reachable from a dataset, from which dotted dimensions like customer.city are derived (ADR 0001 D4).
  # Reads the models' code only, so the boot can use it. belongs_to only: a has_many would duplicate rows.
  module DimensionPaths
    MAX_DEPTH = 2

    # steps: the associations walked. via: every dataset on the way, the target last, since a path needs them all visible.
    Hop = Data.define(:steps, :via) do
      def target = via.last
      def prefix = steps.join(".")
    end

    module_function

    # When a dataset is reached by paths of different lengths, the shortest is kept (ADR 0001 D4, amended 2026-11-07): an invoice
    # has its customer, and its subscription's customer too. Paths of the same length to one dataset are all kept, and the boot
    # refuses them: customer and billing_customer are a real ambiguity.
    def hops(dataset, registry:, tenant_model_name:)
      every = all_hops(dataset, registry, tenant_model_name)
      every.reject { |hop| shadowed?(hop, every) }
    end

    # The paths left out by `hops`, for `rake data_teller:check` to say so.
    def shadowed(dataset, registry:, tenant_model_name:)
      every = all_hops(dataset, registry, tenant_model_name)
      every.select { |hop| shadowed?(hop, every) }.map { |hop| [ hop, every.find { |other| other.target.name == hop.target.name && !shadowed?(other, every) } ] }
    end

    def all_hops(dataset, registry, tenant_model_name)
      klass = ModelLookup.active_record_class(dataset.model_name)
      return [] unless klass

      walk(klass, [], [], [ klass.table_name ], registry, tenant_model_name)
    end

    def shadowed?(hop, every)
      every.any? { |other| other.target.name == hop.target.name && other.steps.size < hop.steps.size }
    end

    # The tenant model is left out: inside a tenant-scoped query every row has the same value there.
    # Each table once: columns are read by table name, so a table met twice would be read under the wrong alias.
    def walk(klass, steps, via, visited, registry, tenant_model_name)
      return [] if steps.size == MAX_DEPTH

      klass.reflect_on_all_associations(:belongs_to).reject(&:polymorphic?).flat_map do |reflection|
        target = target_class(reflection)
        next [] if target.nil? || visited.include?(target.table_name) || target.name == tenant_model_name

        dataset = registry.datasets.find { |candidate| candidate.model_name == target.name }
        next [] unless dataset

        hop = Hop.new(steps: steps + [ reflection.name ], via: via + [ dataset ])
        [ hop, *walk(target, hop.steps, hop.via, visited + [ target.table_name ], registry, tenant_model_name) ]
      end
    end

    def target_class(reflection)
      reflection.klass
    rescue NameError
      nil
    end
  end
end
