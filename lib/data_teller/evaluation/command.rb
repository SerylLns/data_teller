require "json"

module DataTeller
  module Evaluation
    # `rake data_teller:eval`: loads a question set from the app's eval/ directory, asks a model, prints the report, and saves the
    # run when asked. One prompt change, one run, one commit (T14).
    class Command
      MODELS = %w[perfect replay].freeze

      def initialize(root:, split:, model: "perfect", replay: nil, languages: QuestionSet::LANGUAGES, save: false, out: $stdout)
        @root = Pathname(root)
        @split = split
        @model_name = model
        @replay = replay
        @languages = languages
        @save = save
        @out = out
      end

      def call
        set = QuestionSet.load(path)
        report = Report.new(Runner.new(set: set, model: model(set), scorer: scorer(set), languages: @languages).call,
                            split: @split, model: @model, held_out: held_out?)
        @out.print(report.to_text)
        @out.puts("Saved: #{save(report)}") if @save
        report
      end

      private

      def path
        @root.join("eval", "#{@split}.yml").tap do |file|
          raise ArgumentError, "no question set at #{file}" unless file.exist?
        end
      end

      def held_out? = @split == "held_out"

      def model(set)
        @model =
          case @model_name
          when "perfect" then Models::Perfect.new(set)
          when "replay" then Models::Replay.new(@replay || raise(ArgumentError, "MODEL=replay needs REPLAY=<path to a saved run>"))
          else raise ArgumentError, "MODEL must be one of #{MODELS.join(', ')}; a provider comes with the LLM client"
          end
      end

      # The tenant's own time zone, as the compiler uses it. Without the tenant in the database, the rows of a wrong answer cannot
      # be compared: same_result is left out, the score is not.
      def scorer(set)
        tenant = find_tenant(set.tenant)
        time_zone = (tenant && DataTeller.config.time_zone_for(tenant)) || Time.zone
        executor = tenant && Executor.new(tenant: tenant, today: set.today, time_zone: time_zone)
        @out.puts("Tenant #{set.tenant} not found: rows of wrong answers are not compared (seed the database to get them).") unless tenant

        Scorer.new(today: set.today, time_zone: time_zone, executor: executor)
      end

      def find_tenant(name)
        DataTeller.config.tenant_model_name&.constantize&.find_by(name: name)
      rescue ActiveRecord::ActiveRecordError, NameError
        nil
      end

      def save(report)
        stamp = Time.current.utc.strftime("%Y%m%d-%H%M%S")
        file = @root.join("eval", "runs", "#{stamp}-#{@split}-#{@model.name.parameterize}.json")
        FileUtils.mkdir_p(file.dirname)
        file.write(JSON.pretty_generate(report.to_h) + "\n")
        file.relative_path_from(@root)
      end
    end
  end
end
