module DataTeller
  # The catalog of some roles in a few lines per dataset, for a person: what `rake data_teller:schema` sends the LLM is complete but
  # too long to read. Writing evaluation questions, or checking what a role can ask, needs the names and what each one allows.
  # Reads column types, so it runs in a rake task, never at boot.
  class CatalogSummary
    def initialize(catalog)
      @catalog = catalog
    end

    def call
      return "No dataset is visible to #{roles}.\n" if @catalog.datasets.empty?

      header = "Catalog for #{roles}. *: the default date. period: a date to ask about; filter: a value to compare; group: a breakdown.\n"
      header + @catalog.datasets.sort_by(&:name).map { |entry| dataset(entry) }.join("\n")
    end

    private

    def roles = @catalog.roles.join(", ").presence || "no role"

    def dataset(entry)
      synonyms = entry.dataset.synonyms
      lines = [ "#{entry.name}#{" (#{synonyms.join(', ')})" if synonyms.any?}" ]
      lines << "  metrics:  #{entry.metrics.map { |metric| metric_label(metric) }.join(', ')}"
      dates, others = entry.fields.partition(&:date?)
      lines << "  dates:    #{dates.map { |field| date_label(field) }.join(', ')}" if dates.any?
      lines << "  fields:   #{others.map { |field| field_label(field) }.join(', ')}" if others.any?
      lines << "  segments: #{entry.segments.map(&:name).join(', ')}" if entry.segments.any?
      lines.join("\n") + "\n"
    end

    def metric_label(metric)
      detail = metric.ratio? ? "#{metric.of.join(' / ')}" : [ metric.aggregation, metric.column ].compact.join(" ")
      detail = "#{detail}, #{metric.format}" if metric.format
      "#{metric.name} (#{detail})"
    end

    def date_label(field)
      uses = [ ("period" if field.period?), ("group by day..year" if field.groupable?) ].compact
      # The dataset's own default date only: through a path, `time: true` belongs to another dataset.
      "#{field.name}#{'*' if field.dimension.time && field.steps.empty?} (#{uses.join(', ')})"
    end

    def field_label(field)
      kind = field.enum_values ? field.enum_values.join("|") : field.kind
      uses = [ ("filter" if field.filterable?), ("group" if field.groupable?), ("lookup" if field.dimension.lookup) ].compact
      "#{field.name} [#{kind}] (#{uses.join(', ').presence || 'no use'})"
    end
  end
end
