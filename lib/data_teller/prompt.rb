require "digest"

module DataTeller
  # The system message for writing a query (ADR 0009 D2): the task's rules, today in the tenant's time zone, and the role's catalog
  # as compact text. The schema sent with it constrains the output; this says what the names mean.
  #
  # The user's question is not in here: it goes in the user message, apart from the instructions. Nothing in here comes from the
  # database: the catalog is the declarations, and lookup values are not listed.
  class Prompt
    TEMPLATE = <<~TEXT.freeze
      You turn one question about the user's business data into a DataTeller query: a JSON object that the application checks and runs.
      You never write SQL and you never see data. The question may be in English or in French.

      Choose one intent:
      - "answer": the question maps to one dataset of the catalog. Use its names exactly as written.
      - "clarify": the question could mean several things in the catalog (two metrics, two dates, two datasets...). Give the reason and,
        as options, 2 to 6 names from the catalog it could mean.
      - "out_of_scope": the catalog cannot answer it. unknown_dataset: no such kind of record; unknown_metric: the records exist but not
        that measure; unsupported_query: the catalog has it but this question cannot be written as a query; not_a_data_question.

      How an answer is written:
      - metric: one metric of the dataset.
      - period: a date of the dataset (* marks its default) and a range: a relative one (this_month, last_year...), the last n days,
        weeks, months or years, one day, or between two days. Without a period the metric covers all records.
      - filters: a segment of the dataset, or a field compared with an operator. A field marked "lookup" takes {"lookup": "the name as the user wrote it"}.
      - group_by: fields to break the metric down by; a date needs a granularity (day to year). order_by and limit make a top N.
      - compare: previous_period or previous_year, with a period.

      Today is %<today>s (%<time_zone>s). When the question is relative ("last month", "this year"), use a relative range.

      %<catalog>s
    TEXT

    # Names the prompt in saved runs: one prompt change, one run (T14).
    def self.fingerprint = Digest::SHA256.hexdigest(TEMPLATE)[0, 12]

    def initialize(catalog, today:, time_zone:)
      @catalog = catalog
      @today = today
      @time_zone = time_zone
    end

    def system
      format(TEMPLATE, today: @today.iso8601, time_zone: @time_zone.tzinfo.name, catalog: CatalogSummary.new(@catalog).call.chomp)
    end
  end
end
