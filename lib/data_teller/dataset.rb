require "active_support/core_ext/string/inflections"

module DataTeller
  # roles is required by boot validation (T07, ADR 0004 D5); it is allowed to be nil here so that the validator
  # can report every missing declaration at once instead of failing on the first one.
  class Dataset < Data.define(:name, :model_name, :roles, :metrics, :dimensions, :segments, :synonyms)
    def initialize(model_name:, name: nil, roles: nil, metrics: [], dimensions: [], segments: [], synonyms: [])
      model_name = model_name.to_s
      derived = model_name.demodulize.underscore.pluralize

      super(
        name: NameFormat.ensure!(name || derived, "dataset"),
        model_name: model_name.freeze,
        roles: NameFormat.roles(roles, "dataset"),
        metrics: index_by_name(metrics, "metric"),
        dimensions: index_by_name(dimensions, "dimension"),
        segments: index_by_name(segments, "segment"),
        synonyms: synonyms.map { |s| s.to_s.strip.freeze }.reject(&:empty?).uniq.freeze
      )
    end

    # Plain, key-sorted structure: stable input for the registry fingerprint.
    def to_h
      {
        name: name,
        model: model_name,
        roles: roles&.sort,
        synonyms: synonyms.sort,
        metrics: metrics.sort.to_h { |key, metric| [ key, metric.to_h ] },
        dimensions: dimensions.sort.to_h { |key, dimension| [ key, dimension.to_h ] },
        segments: segments.sort.to_h { |key, segment| [ key, segment.to_h ] }
      }
    end

    private

    def index_by_name(items, kind)
      items.each_with_object({}) do |item, index|
        raise DeclarationError, "dataset #{model_name}: #{kind} #{item.name.inspect} is declared twice" if index.key?(item.name)

        index[item.name] = item
      end.freeze
    end
  end
end
