module DataTeller
  # The block given to `DataTeller.refine`. It only collects declarations and hands them to the immutable value
  # objects, which do the validation: nothing in here evaluates user input or reads the database.
  # A bad line does not stop the block, so that one run reports every mistake of a dataset.
  class DatasetBuilder
    METRIC_OPTIONS = %i[format sensitive roles].freeze

    def initialize(model_name, name: nil)
      @model_name = model_name
      @name = name
      @roles = nil
      @tenant_path = nil
      @synonyms = []
      @metrics = []
      @dimensions = []
      @segments = []
      @min_group_size = nil
      @always = []
      @list = nil
      @problems = []
    end

    def roles(*names)
      @roles = names.flatten
    end

    def tenant_path(*steps)
      @tenant_path = steps.flatten
    end

    def synonyms(*words)
      @synonyms.concat(words.flatten)
    end

    def metric(name, **options)
      collect_problems { @metrics << build_metric(name, options) }
    end

    def dimension(name, **options)
      collect_problems { @dimensions << Dimension.new(name: name, **options) }
    end

    def segment(name, **options)
      collect_problems { @segments << Segment.new(name: name, **options) }
    end

    # min_group_size 5, of: :customer, except: %i[admin] (ADR 0012).
    def min_group_size(minimum, of: nil, except: [])
      collect_problems { @min_group_size = MinGroupSize.new(minimum: minimum, of: of, except: except) }
    end

    # always scope: :visible, or always where: { archived: false } (ADR 0014).
    def always(**options)
      collect_problems { @always << Always.new(**options) }
    end

    # list default: %i[ordered_at status] (ADR 0016).
    def list(**options)
      collect_problems { @list = ListDeclaration.new(**options) }
    end

    def build
      dataset = collect_problems do
        Dataset.new(
          model_name: @model_name, name: @name, roles: @roles, tenant_path: @tenant_path, synonyms: @synonyms,
          metrics: with_implicit_count(@metrics), dimensions: @dimensions, segments: @segments, min_group_size: @min_group_size,
          always: @always, list: @list
        )
      end
      raise DeclarationError.new(@problems) if @problems.any?

      dataset
    end

    private

    # `count` exists on every dataset without being declared (ADR 0004 D2); declaring it explicitly overrides it,
    # for instance to restrict its roles.
    def with_implicit_count(metrics)
      return metrics if metrics.any? { |metric| metric.name == :count }

      [ Metric.new(name: :count, aggregation: :count), *metrics ]
    end

    # min_group_size 5, of: :customer, except: %i[admin] (ADR 0012).
    def min_group_size(minimum, of: nil, except: [])
      collect_problems { @min_group_size = MinGroupSize.new(minimum: minimum, of: of, except: except) }
    end

    def build_metric(name, options)
      common = options.slice(*METRIC_OPTIONS)
      aggregations = options.except(*METRIC_OPTIONS)
      aggregation, argument = aggregations.first

      if aggregations.size > 1
        raise DeclarationError, "metric #{name.inspect}: give one aggregation, got #{aggregations.keys.inspect}"
      end
      aggregation, argument = :count, true if aggregations.empty? && name.to_s == "count"
      raise DeclarationError, "metric #{name.inspect}: give an aggregation, e.g. sum: :total_cents" if aggregation.nil?

      case aggregation
      when :count then count_metric(name, argument, common)
      when :ratio then Metric.new(name: name, aggregation: :ratio, of: argument, **common)
      else Metric.new(name: name, aggregation: aggregation, column: argument, **common)
      end
    end

    def count_metric(name, argument, common)
      raise DeclarationError, "metric #{name.inspect}: count takes no column, write `count: true`" unless argument == true

      Metric.new(name: name, aggregation: :count, **common)
    end

    # Unknown keywords surface as ArgumentError from Data.define; report them like any other declaration error.
    def collect_problems
      yield
    rescue DeclarationError => e
      @problems.concat(e.problems)
      nil
    rescue ArgumentError => e
      @problems << "dataset #{@model_name}: #{e.message}"
      nil
    end
  end
end
