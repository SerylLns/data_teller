module DataTeller
  # From a query to an ActiveRecord relation (ADR 0005). It validates the query itself, so that nothing reaches SQL without
  # going through QueryValidator, even when called directly. Column names come from the catalog, never from the query.
  class Compiler
    class Refused < Error
      # codes: the validator's problem codes when it refused, never a value (QueryValidator#problems). For the isolation kit,
      # which says why a query was not tried; the end user only ever sees `reason`.
      attr_reader :reason, :codes

      def initialize(reason = :unsupported_query, message = nil, codes: [])
        @reason = reason
        @codes = codes
        super(message || reason.to_s)
      end
    end

    # A parameter the database receives apart from the SQL: the query's text can never become part of the statement.
    # What a cursor value may be (ADR 0016 D4): the scalars a filter takes, a string no longer than a name, no NUL byte.
    CURSOR_VALUE = lambda do |value|
      value.nil? || value == true || value == false || (value.is_a?(Numeric) && value.finite?) ||
        (value.is_a?(String) && value.size <= 200 && !value.include?("\u0000"))
    end

    def self.bind(klass, column, value)
      Arel::Nodes::BindParam.new(
        ActiveRecord::Relation::QueryAttribute.new(column.to_s, value, klass.type_for_attribute(column.to_s))
      )
    end

    def initialize(catalog:, tenant:, time_zone:, now:)
      @catalog = catalog
      @tenant_scope = TenantScope.new(tenant)
      @time_zone = time_zone
      @now = now
    end

    # after: the cursor of a list's next page, as the previous page gave it (ADR 0016 D4). Untrusted like the query: checked below.
    def call(query, after: nil)
      validation = QueryValidator.new(@catalog).call(query)
      raise Refused.new(validation.refusal.reason, codes: validation.problems.map { |problem| problem[:code] }.uniq) unless validation.ok?
      raise Refused.new(:unsupported_query, "only an answer compiles") unless query["intent"] == "answer"

      @group_nodes = nil
      @query = query
      @entry = @catalog.dataset(query["dataset"])
      @klass = @entry.model_name.constantize
      @metric = @entry.metrics.find { |metric| metric.name.to_s == query["metric"] }
      return build_list(current_period, after) if query["list"]
      raise Refused.new(:unsupported_query, "only a list has pages") if after

      query["compare"] ? build_comparison : build_plan(current_period)
    end

    private

    def periods = PeriodResolver.new(time_zone: @time_zone, now: @now)
    def current_period = @query["period"] && periods.call(@query["period"]["range"])

    def build_comparison
      compared = periods.compared(@query["period"]["range"], @query["compare"])

      ComparedPlan.new(
        current: build_plan(compared.current),
        previous: build_plan(compared.previous),
        group_columns: group_fields.map { |found| [ found.model, found.dimension.column ] },
        metric_name: @metric.name
      )
    end

    def build_plan(period)
      @period = period
      check_join_cap
      check_tables_joined_once
      check_default_scopes
      # A default order cannot apply to an aggregate. Everything else a default_scope could hold is refused just above.
      relation = apply_scope_segments(@klass.all.unscope(:order))
      relation = apply_joins(relation)
      relation = apply_always(relation)
      relation = apply_conditions(relation)

      # Last on purpose: a scope above can hold anything, and nothing below removes a condition (ADR 0005 D1).
      filters = tenant_filters
      relation = filters.reduce(relation) { |current, condition| current.where(condition) }
      relation = apply_grouping(relation)
      relation = relation.having(big_enough) if big_enough

      unless @tenant_scope.present_in?(relation, filters)
        raise Refused.new(:unsupported_query, "a tenant filter is missing from the final relation")
      end

      Plan.new(relation: relation, columns: columns, selection: selection, decoders: decoders, limit: row_limit, series: series, period: period,
               touched: touched_datasets, big_enough: big_enough)
    end

    # ---- what the query touches

    def filter_items = Array(@query["filters"])
    def group_items = Array(@query["group_by"])

    def field(name) = @entry.fields.find { |candidate| candidate.name.to_s == name }

    def comparisons = filter_items.select { |item| item.key?("dimension") }
    def segments = filter_items.select { |item| item.key?("segment") }.map { |item| @entry.segments.find { |s| s.name.to_s == item["segment"] } }
    def group_fields = group_items.map { |item| field(item["dimension"]) }
    def period_field = @query["period"] && field(@query["period"]["dimension"])

    def fields_used
      [ *comparisons.map { |item| field(item["dimension"]) }, *group_fields, period_field, *list_fields, list_order_field ].compact.uniq(&:name)
    end

    def metric_steps = @metric ? @metric.steps : []

    def touched_datasets
      [ *fields_used.flat_map(&:via), *metric_path_datasets, @entry.dataset ].uniq(&:name)
    end

    # ---- segments and joins

    def check_join_cap
      joined = touched_datasets.size - 1
      return if joined <= limits.max_joins

      raise Refused.new(:unsupported_query, "#{joined} tables joined, the limit is #{limits.max_joins}")
    end

    # Rails gives a table joined a second time an alias. The columns and the tenant filter read the table by its name, so they
    # would all be on the first join: a sum of the wrong rows, and a second join with no filter. Per query, because each path is
    # fine alone: a dataset can have both, as long as one query does not use both.
    def check_tables_joined_once
      reached = { @klass.table_name => [] }

      join_paths.each do |steps|
        steps.each_index.reduce(@klass) do |klass, index|
          target = klass.reflect_on_association(steps[index])&.klass
          raise Refused.new(:unsupported_query, "#{klass.name} has no association #{steps[index]}") unless target

          path = steps[0..index]
          raise Refused.new(:unsupported_query, "this query reaches #{target.table_name} by two paths") unless (reached[target.table_name] ||= path) == path

          target
        end
      end
    end

    def check_default_scopes
      touched_datasets.each { |dataset| ScopeInspector.check_default_scope(dataset.model_name.constantize) }
    rescue ScopeInspector::Rejected => e
      raise Refused.new(:unsupported_query, e.message)
    end

    # Added as conditions, never merged: `merge` replaces an earlier condition on the same column.
    def apply_scope_segments(relation)
      segments.select(&:scope?).reduce(relation) do |current, segment|
        conditions = ScopeInspector.conditions(@klass, segment.scope)
        conditions ? current.where(conditions) : current
      end
    rescue ScopeInspector::Rejected => e
      raise Refused.new(:unsupported_query, e.message)
    end

    # Every table read, joined ones included, as a default_scope would be (ADR 0014 D2). Each condition is an Arel node on its own
    # table: a hash given to `where` would be read against the dataset's table.
    def apply_always(relation)
      touched_datasets.reduce(relation) do |current, dataset|
        klass = dataset.model_name.constantize
        dataset.always.filter_map { |condition| always_node(klass, condition) }.reduce(current) { |inner, node| inner.where(node) }
      end
    rescue ScopeInspector::Rejected => e
      raise Refused.new(:unsupported_query, e.message)
    end

    def always_node(klass, condition)
      return ScopeInspector.conditions(klass, condition.scope) if condition.scope?

      Arel::Nodes::Grouping.new(klass.unscoped.where(condition.where).where_clause.ast)
    end

    def apply_joins(relation)
      join_paths.reduce(relation) { |current, steps| current.joins(nested(steps)) }
    end

    def join_paths = [ *fields_used.map(&:steps), metric_steps ].reject(&:empty?).uniq

    def nested(steps)
      steps.reverse.reduce { |inner, step| { step => inner } }
    end

    # ---- conditions

    def apply_conditions(relation)
      relation = segments.reject(&:scope?).reduce(relation) { |current, segment| current.where(declarative(segment)) }
      relation = comparisons.reduce(relation) { |current, item| current.where(comparison(item)) }
      period_field ? relation.where(period_condition) : relation
    end

    def declarative(segment)
      if segment.where.values.any? { |value| value.is_a?(Hash) }
        raise Refused.new(:unsupported_query, "relative conditions in segments are not implemented yet")
      end

      segment.where
    end

    def comparison(item)
      found = field(item["dimension"])
      klass = found.model
      column = found.dimension.column
      attribute = klass.arel_table[column]
      value = item["value"]

      case item["op"]
      when "eq" then attribute.eq(bound(klass, column, value))
      when "not_eq" then attribute.not_eq(bound(klass, column, value))
      when "gt" then attribute.gt(bound(klass, column, value))
      when "gte" then attribute.gteq(bound(klass, column, value))
      when "lt" then attribute.lt(bound(klass, column, value))
      when "lte" then attribute.lteq(bound(klass, column, value))
      when "in" then attribute.in(value.map { |one| bound(klass, column, one) })
      when "not_in" then attribute.not_in(value.map { |one| bound(klass, column, one) })
      when "contains" then attribute.matches(bound(klass, column, "%#{klass.sanitize_sql_like(value)}%"))
      when "is_null" then attribute.eq(nil)
      when "is_not_null" then attribute.not_eq(nil)
      # An operator added to the format without its SQL here must not silently become no condition at all.
      else raise Refused.new(:unsupported_query, "unknown operator")
      end
    end

    def bound(klass, column, value)
      raise Refused.new(:unsupported_query, "lookups are not implemented yet") if value.is_a?(Hash)

      self.class.bind(klass, column, value)
    end

    def period_condition
      found = period_field
      klass = found.model
      column = found.dimension.column
      attribute = klass.arel_table[column]
      from, to = @period

      attribute.gteq(self.class.bind(klass, column, boundary(klass, column, from)))
               .and(attribute.lt(self.class.bind(klass, column, boundary(klass, column, to))))
    end

    # A day starts at a different instant in each time zone: a datetime is compared to the tenant's midnight.
    def boundary(klass, column, day)
      return day if klass.type_for_attribute(column).type == :date

      @time_zone.local(day.year, day.month, day.day)
    end

    # ---- tenant

    # The dataset's own table comes last, the tables reached through paths before it: all of them get their own filter.
    def tenant_filters
      touched_datasets.map do |dataset|
        @tenant_scope.condition_for(dataset.model_name.constantize, dataset.tenant_path)
      end
    end

    def metric_path_datasets
      return [] if metric_steps.empty?

      datasets = []
      ModelLookup.follow_metric_path(@klass, metric_steps) do |reflection|
        # The boot refuses a path through a model that is not exposed; this is the last line if that ever changes.
        datasets << (@catalog.dataset_for_model(reflection.class_name) || raise(Refused.new(:unsupported_query, "no tenant_path for a metric path")))
      end
      datasets
    rescue ModelLookup::PathError => e
      raise Refused.new(:unsupported_query, e.message)
    end

    # ---- lists (ADR 0016)

    def list_fields
      return [] unless @query["list"]

      names = @query["columns"] || @entry.dataset.list.default.map(&:to_s)
      names.filter_map { |name| field(name) }
    end

    # The query's order, else the default time dimension, newest first; nil when the dataset has neither, and the key orders alone.
    def list_order_field
      return nil unless @query["list"]

      @query["order_by"] ? field(@query["order_by"]["dimension"]) : @entry.fields.find { |found| found.steps.empty? && found.dimension.time }
    end

    def list_direction = @query["order_by"] ? @query["order_by"]["dir"] : "desc"

    def build_list(period, after)
      @period = period
      check_join_cap
      check_tables_joined_once
      check_default_scopes
      # The validator refuses these already; the compiler is called directly too, and a list must never read rows a threshold protects.
      raise Refused.new(:unsupported_query, "a list cannot read a dataset under min_group_size") if big_enough

      key = primary_key_field
      relation = apply_conditions(apply_always(apply_joins(apply_scope_segments(@klass.all.unscope(:order)))))
      filters = tenant_filters
      relation = filters.reduce(relation) { |current, condition| current.where(condition) }
      unless @tenant_scope.present_in?(relation, filters)
        raise Refused.new(:unsupported_query, "a tenant filter is missing from the final relation")
      end

      counted = relation
      keys = [ (order_attribute if list_order_field), key ].compact
      relation = relation.where(after_condition(keys, after)) if after
      relation = relation.order(*keys.map { |attribute| directed_nulls_last(attribute, list_direction) })

      ListPlan.new(relation: relation, columns: list_fields.map { |found| found.name.to_s }, selection: [ *list_attributes, *keys ],
                   decoders: list_fields.map { |found| list_decoder(found) }, keys: cursor_encoders, page: page_size(after),
                   shown: after ? shown_before(after) : 0, cap: @query["limit"], counted: counted, period: period, touched: touched_datasets)
    end

    def list_attributes = list_fields.map { |found| found.model.arel_table[found.dimension.column] }
    def order_attribute = list_order_field.model.arel_table[list_order_field.dimension.column]

    # A page cannot be found again without a total order: rows with the same date would move from one page to the next.
    def primary_key_field
      key = @klass.primary_key
      raise Refused.new(:unsupported_query, "#{@klass.name} has no single primary key to page by") unless key.is_a?(String)

      @klass.arel_table[key]
    end

    # Rows with no value come last in both directions, so the cursor of a NULL is past every value.
    def directed_nulls_last(node, direction)
      direction == "desc" ? Arel::Nodes::Descending.new(node).nulls_last : Arel::Nodes::Ascending.new(node).nulls_last
    end

    def page_size(after)
      size = limits.max_list_rows
      return size unless @query["limit"]

      [ size, @query["limit"] - (after ? shown_before(after) : 0) ].min.clamp(1, size)
    end

    # The order value as a filter would compare it, then the key, for the next page; only what was sent before is read.
    def cursor_encoders
      key = ->(raw) { raw }
      return [ key ] unless list_order_field

      [ ->(raw) { cursor_value(raw) }, key ]
    end

    def cursor_value(raw)
      case raw
      when ActiveSupport::TimeWithZone, Time, DateTime then raw.utc.iso8601(6)
      when Date then raw.iso8601
      else list_order_field.kind == :enum ? list_decoder(list_order_field).call(raw) : raw
      end
    end

    # ---- the cursor, sent back by the client: never trusted, every value bound through its column's type

    def shown_before(after)
      shown = after["shown"]
      return shown if shown.is_a?(Integer) && shown.positive? && shown < 1_000_000

      raise Refused.new(:unsupported_query, "invalid cursor", codes: [ :invalid_cursor ])
    end

    def after_condition(keys, after)
      values = after.is_a?(Hash) && after["values"]
      unless values.is_a?(Array) && values.size == keys.size && values.all?(&CURSOR_VALUE) && !values.last.nil? && shown_before(after)
        raise Refused.new(:unsupported_query, "invalid cursor", codes: [ :invalid_cursor ])
      end

      key_value = bind_key(values.last)
      return keyed_after(keys.last, key_value) if keys.one?

      ordered_after(keys.first, values.first, keys.last, key_value)
    end

    def bind_key(value) = self.class.bind(@klass, @klass.primary_key, value)

    def keyed_after(key, value) = list_direction == "desc" ? key.lt(value) : key.gt(value)

    # (value, key) strictly after the last row, NULLs last in both directions.
    def ordered_after(attribute, value, key, key_value)
      if value.nil?
        attribute.eq(nil).and(keyed_after(key, key_value))
      else
        bound = self.class.bind(list_order_field.model, list_order_field.dimension.column, value)
        beyond = list_direction == "desc" ? attribute.lt(bound) : attribute.gt(bound)
        Arel::Nodes::Grouping.new(beyond.or(attribute.eq(bound).and(keyed_after(key, key_value))).or(attribute.eq(nil)))
      end
    end

    # Enum names, as everywhere else; datetimes in the tenant's zone, the zone its "today" is in.
    def list_decoder(found)
      return decoder_for(found) if found.kind == :enum
      return nil unless found.date?

      ->(raw) { raw.respond_to?(:in_time_zone) && !raw.is_a?(Date) ? raw.in_time_zone(@time_zone) : raw }
    end

    # ---- minimum group size (ADR 0012)

    # Every protected dataset the query reads, for these roles, counted by its own unit (D4). Each is already in the FROM or a JOIN, since it
    # was touched, so counting it adds no table. nil when no threshold applies.
    def big_enough
      sizes = touched_datasets.filter_map do |dataset|
        size = dataset.min_group_size
        next unless size&.applies_to?(@catalog.roles)

        group_size(dataset, size).gteq(size.minimum)
      end
      sizes.reduce { |all, one| all.and(one) }
    end

    def group_size(dataset, size)
      # COUNT(*) only where it equals COUNT(DISTINCT): the distinct count makes Postgres sort every row of the group, with no hash
      # aggregate and no parallel workers, measured 12x slower on 500k rows (ADR 0012 D3).
      return Arel.star.count if dataset.name == @entry.dataset.name && size.of.nil? && own_rows_unique?

      model = dataset.model_name.constantize
      column = size.of ? model.reflect_on_association(size.of)&.foreign_key&.to_s : model.primary_key
      # Fail closed: the boot checks the unit, and a table with no single key cannot be counted, so it cannot be shown.
      raise Refused.new(:unsupported_query, "#{model.name} has no single key to count its groups by") unless column.is_a?(String)

      model.arel_table[column].count(true)
    end

    # Each row of the dataset appears once in the joined rows when every join is a belongs_to on the parent's primary key: one parent
    # at most per row. A has_many on a metric path, or a key that is not unique, repeats it.
    def own_rows_unique?
      join_paths.all? do |steps|
        steps.reduce(@klass) do |klass, step|
          reflection = klass.reflect_on_association(step)
          return false unless reflection&.belongs_to? && !reflection.polymorphic? && reflection.association_primary_key == reflection.klass.primary_key

          reflection.klass
        end
      end
    end

    # ---- grouping and output

    def group_nodes
      @group_nodes ||= group_items.map { |item| group_node(field(item["dimension"]), item["granularity"]) }
    end

    def group_node(found, granularity)
      attribute = found.model.arel_table[found.dimension.column]
      granularity ? truncated_date(found, attribute, granularity) : attribute
    end

    # The granularity comes from a closed list and the zone from ActiveSupport::TimeZone. They are quoted, not bound, because
    # Postgres sees different parameters in SELECT and GROUP BY as different expressions.
    def truncated_date(found, attribute, granularity)
      local = found.model.type_for_attribute(found.dimension.column).type == :date ? attribute : in_tenant_zone(found, attribute)
      truncated = Arel::Nodes::NamedFunction.new("date_trunc", [ Arel::Nodes.build_quoted(granularity), cast(local, "timestamp") ])

      cast(truncated, "date")
    end

    def in_tenant_zone(found, attribute)
      column = found.model.columns_hash[found.dimension.column]
      raise Refused.new(:unsupported_query, "no such column") unless column
      # Without a zone in the column, this reads it as UTC. Period boundaries go through the attribute type instead, so on
      # another setting the two would disagree and shift every group.
      unless column.sql_type.include?("with time zone") || ActiveRecord.default_timezone == :utc
        raise Refused.new(:unsupported_query, "date grouping needs timestamps stored in UTC")
      end

      utc = column.sql_type.include?("with time zone") ? attribute : at_zone(attribute, "UTC")

      at_zone(utc, @time_zone.tzinfo.name)
    end

    def at_zone(node, zone)
      Arel::Nodes::InfixOperation.new("AT TIME ZONE", node, Arel::Nodes.build_quoted(zone))
    end

    def cast(node, type)
      Arel::Nodes::NamedFunction.new("CAST", [ node.as(type) ])
    end

    def metric_node(metric = @metric)
      case metric.aggregation
      when :count then Arel.star.count
      when :ratio then ratio_node(metric)
      else aggregate_node(metric)
      end
    end

    def aggregate_node(metric)
      owner, column = ModelLookup.column_owner(@klass, metric.column)
      attribute = owner.arel_table[column]

      case metric.aggregation
      when :sum then attribute.sum
      when :avg then attribute.average
      when :min then attribute.minimum
      when :max then attribute.maximum
      when :count_distinct then attribute.count(true)
      end
    end

    # NULLIF: dividing by zero must give no value, not an SQL error. 1.0: an integer division would round.
    def ratio_node(metric)
      numerator, denominator = metric.of.map { |name| metric_node(@entry.dataset.metrics.fetch(name)) }
      dividend = Arel::Nodes::Multiplication.new(numerator, Arel.sql("1.0"))
      divisor = Arel::Nodes::NamedFunction.new("NULLIF", [ denominator, Arel.sql("0") ])

      Arel::Nodes::Division.new(dividend, divisor)
    end

    def apply_grouping(relation)
      return relation if group_nodes.empty?

      relation.group(*group_nodes).order(*ordering)
    end

    # A top N with ties would change from one run to the next without the group columns as a tie-break.
    def ordering
      order_by = @query["order_by"]
      first =
        if order_by&.fetch("by") == "dimension"
          directed(group_nodes[group_items.index { |item| item["dimension"] == order_by["dimension"] }], order_by["dir"])
        elsif order_by
          directed(metric_node, order_by["dir"])
        elsif high_cardinality_field
          directed(metric_node, "desc")
        end

      [ first, *group_nodes.map { |node| directed(node, "asc") } ].compact
    end

    # NULLS LAST: Postgres sorts NULL first on DESC, so groups with no value would take the top of a capped top N.
    def directed(node, direction)
      direction == "desc" ? Arel::Nodes::Descending.new(node).nulls_last : Arel::Nodes::Ascending.new(node)
    end

    def high_cardinality_field
      group_fields.find(&:high_cardinality?)
    end

    # Grouping by a high-cardinality dimension is capped, the query's own limit can only lower that (ADR 0004 D3).
    def row_limit
      return nil if group_nodes.empty?
      return limits.max_rows if time_series?

      cap = high_cardinality_field ? (high_cardinality_field.dimension.max_groups || limits.default_max_groups) : limits.max_rows
      [ @query["limit"], cap ].compact.min
    end

    def series
      return nil unless time_series?

      Plan::Series.new(columns: group_fields.each_index.select { |index| group_fields[index].date? }, max_points: limits.max_time_points)
    end

    # A series the user did not cap themselves. Cutting it would hide its end: "by day over 5 years" needs a wider granularity.
    def time_series?
      @query["limit"].nil? && !high_cardinality_field && group_fields.any?(&:date?)
    end

    def limits = DataTeller.config

    def selection = [ *group_nodes, metric_node ]
    def columns = [ *group_items.map { |item| item["dimension"] }, @metric.name.to_s ]

    def decoders
      [ *group_fields.map { |found| decoder_for(found) }, metric_decoder ]
    end

    # Enums are stored as integers and read by their name.
    def decoder_for(found)
      return nil unless found.kind == :enum

      type = found.model.type_for_attribute(found.dimension.column)
      ->(raw) { type.deserialize(raw) }
    end

    # A sum over no rows is 0. An average or a ratio over no rows has no value, and saying 0 would be false.
    def metric_decoder
      %i[sum count count_distinct].include?(@metric.aggregation) ? ->(raw) { raw || 0 } : nil
    end
  end
end
