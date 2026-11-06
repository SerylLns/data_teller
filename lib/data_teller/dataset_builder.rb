module DataTeller
  # The block given to `DataTeller.refine`. It only collects declarations and hands them to the immutable value
  # objects, which do the validation: nothing in here evaluates user input or reads the database.
  class DatasetBuilder
    METRIC_OPTIONS = %i[format roles].freeze

    def initialize(model_name, name: nil)
      @model_name = model_name
      @name = name
      @roles = nil
      @synonyms = []
      @metrics = []
      @dimensions = []
      @segments = []
    end

    def roles(*names)
      @roles = names.flatten
    end

    def synonyms(*words)
      @synonyms.concat(words.flatten)
    end

    def metric(name, **options)
      @metrics << build_metric(name, options)
    end

    def dimension(name, **options)
      @dimensions << collect_errors { Dimension.new(name: name, **options) }
    end

    def segment(name, **options)
      @segments << collect_errors { Segment.new(name: name, **options) }
    end

    def build
      Dataset.new(
        model_name: @model_name, name: @name, roles: @roles, synonyms: @synonyms,
        metrics: with_implicit_count(@metrics), dimensions: @dimensions, segments: @segments
      )
    end

    private

    # `count` exists on every dataset without being declared (ADR 0004 D2); declaring it explicitly overrides it,
    # for instance to restrict its roles.
    def with_implicit_count(metrics)
      return metrics if metrics.any? { |metric| metric.name == :count }

      [ Metric.new(name: :count, aggregation: :count), *metrics ]
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

      collect_errors do
        case aggregation
        when :count then count_metric(name, argument, common)
        when :ratio then Metric.new(name: name, aggregation: :ratio, of: argument, **common)
        else Metric.new(name: name, aggregation: aggregation, column: argument, **common)
        end
      end
    end

    def count_metric(name, argument, common)
      raise DeclarationError, "metric #{name.inspect}: count takes no column, write `count: true`" unless argument == true

      Metric.new(name: name, aggregation: :count, **common)
    end

    # Unknown keywords surface as ArgumentError from Data.define; report them like any other declaration error.
    def collect_errors
      yield
    rescue ArgumentError => e
      raise DeclarationError, "dataset #{@model_name}: #{e.message}"
    end
  end
end
