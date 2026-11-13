require "active_support/core_ext/string/inflections"

module DataTeller
  # roles is required by boot validation (T07, ADR 0004 D5); it is allowed to be nil here so that the validator
  # can report every missing declaration at once instead of failing on the first one.
  # min_group_size: a MinGroupSize, nil when the dataset declares none (ADR 0012).
  class Dataset < Data.define(:name, :model_name, :roles, :tenant_path, :metrics, :dimensions, :segments, :synonyms, :min_group_size)
    def initialize(model_name:, name: nil, roles: nil, tenant_path: nil, metrics: [], dimensions: [], segments: [], synonyms: [],
                   min_group_size: nil)
      model_name = model_name.to_s
      derived = model_name.demodulize.underscore.pluralize

      super(
        name: NameFormat.ensure!(name || derived, "dataset"),
        model_name: model_name.freeze,
        roles: NameFormat.roles(roles, "dataset"),
        tenant_path: tenant_steps(model_name, tenant_path),
        metrics: index_by_name(model_name, metrics, "metric"),
        dimensions: index_by_name(model_name, dimensions, "dimension"),
        segments: index_by_name(model_name, segments, "segment"),
        synonyms: synonyms.map { |s| s.to_s.strip.freeze }.reject(&:empty?).uniq.freeze,
        min_group_size: min_group_size
      )
    end

    # Plain, key-sorted structure: stable input for the registry fingerprint.
    def to_h
      {
        name: name,
        model: model_name,
        roles: roles&.sort,
        tenant_path: tenant_path,
        synonyms: synonyms.sort,
        metrics: metrics.sort.to_h { |key, metric| [ key, canonical_member(metric) ] },
        dimensions: dimensions.sort.to_h { |key, dimension| [ key, canonical_member(dimension) ] },
        segments: segments.sort.to_h { |key, segment| [ key, canonical_member(segment) ] },
        min_group_size: min_group_size && canonical(min_group_size.to_h)
      }
    end

    private

    # nil is allowed here for the same reason as roles; the order of the steps is the path itself.
    def tenant_steps(model_name, steps)
      return nil if steps.nil?
      raise DeclarationError, "dataset #{model_name}: tenant_path needs at least one association" if steps.empty?

      steps.map { |step| NameFormat.ensure!(step, "dataset #{model_name}: tenant_path step") }.freeze
    end

    # `of` keeps its order: a / b is not b / a. Everything else is a set, or a condition whose order means nothing.
    def canonical_member(member)
      member.to_h.to_h { |key, value| [ key, key == :of ? value : canonical(value) ] }
    end

    def canonical(value)
      case value
      when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [ key, canonical(item) ] }
      when Array then value.map { |item| canonical(item) }.sort_by(&:to_s)
      else value
      end
    end

    # model_name is passed in because the reader returns nil until `super` has run.
    def index_by_name(model_name, items, kind)
      items.each_with_object({}) do |item, index|
        raise DeclarationError, "dataset #{model_name}: #{kind} #{item.name.inspect} is declared twice" if index.key?(item.name)

        index[item.name] = item
      end.freeze
    end
  end
end
