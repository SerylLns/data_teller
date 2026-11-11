module DataTeller
  class IsolationCheck
    # rake data_teller:isolation (ADR 0011 D2): runs the check, prints the report, returns the exit status. Non-zero on a leak, and
    # on nothing to check: a CI that is green because no tenant exists would be green for nothing.
    # The output holds dataset names, query shapes and primary keys only: it ends up in CI logs.
    class Command
      MAX_LINES = 50 # per kind of problem: past that, the count says enough and a log stays readable.

      class Usage < StandardError; end

      def initialize(env: ENV, out: $stdout, config: DataTeller.config)
        @env = env
        @out = out
        @config = config
      end

      def call
        return fail_with("DataTeller is disabled: run rake data_teller:check") unless DataTeller.enabled?

        tenants = chosen_tenants
        return fail_with("no #{@config.tenant_model_name} in this database: there is nothing to check") if tenants.empty?

        check = IsolationCheck.new(config: @config, tenants: tenants, cap: @cap = cap)
        report = check.call
        print_report(report, check.dataset_names)
        report.failed? ? 1 : 0
      rescue Usage => e
        fail_with(e.message)
      end

      private

      def tenant_model = @config.tenant_model_name.constantize

      # TENANTS=12,57,301 replaces the default three, in that order.
      def chosen_tenants
        ids = @env["TENANTS"]&.split(",")&.map(&:strip)&.reject(&:empty?)
        return IsolationCheck.default_tenants(tenant_model) if ids.nil? || ids.empty?

        found = tenant_model.unscoped.where(tenant_model.primary_key => ids).index_by { |tenant| tenant.public_send(tenant_model.primary_key).to_s }
        missing = ids - found.keys
        raise Usage, "TENANTS: no #{@config.tenant_model_name} with id #{missing.join(', ')}" if missing.any?

        ids.map { |id| found[id] }
      end

      def cap
        value = @env.fetch("CAP", IsolationCheck::DEFAULT_CAP.to_s)
        number = Integer(value, 10, exception: false)
        raise Usage, "CAP must be a positive number of rows, got #{value.inspect}" unless number&.positive?

        number
      end

      def print_report(report, dataset_names)
        say "DataTeller isolation check: #{@config.tenant_model_name} #{report.tenants.join(', ')} · #{report.runs.size} queries · " \
            "at most #{@cap} rows checked per query"
        if @config.row_security
          say "Row security is on: the database filters too, so a compiler bug it masks would not show here."
        end

        problems(report)
        rows_read(report, dataset_names)
        warnings(report, dataset_names)
        verdict(report)
      end

      def problems(report)
        leaking = report.runs.flat_map { |run| run.leaks.map { |leak| [ run, leak ] } }
        listed(leaking) do |run, leak|
          owner = leak.owner.nil? ? "no tenant" : "#{@config.tenant_model_name} #{leak.owner}"
          "LEAK      #{where(run)}: #{leak.dataset} #{leak.key} belongs to #{owner}"
        end

        unlisted = report.runs.flat_map { |run| run.unlisted.map { |table| [ run, table ] } }
        listed(unlisted) { |run, table| "UNFILTERED #{where(run)}: reads #{table}, which got no tenant filter" }
      end

      def rows_read(report, dataset_names)
        totals = report.rows_read
        width = dataset_names.map(&:length).max.to_i

        say ""
        say "Rows checked per dataset, all queries together (#{@config.tenant_model_name} #{report.tenants.join(' / ')}):"
        dataset_names.each do |name|
          say "  #{name.ljust(width)}  #{report.tenants.map { |tenant| totals[name][tenant] }.join(' / ')}"
        end
      end

      def warnings(report, dataset_names)
        say ""
        not_proved = report.not_proved(dataset_names)
        say "warning: not proved, no chosen tenant read a row of: #{not_proved.join(', ')}" if not_proved.any?

        unkeyed = report.runs.flat_map(&:unkeyed).uniq
        say "warning: not proved, no single primary key: #{unkeyed.join(', ')}" if unkeyed.any?

        partial = report.runs.select(&:partial)
        say "warning: #{partial.size} queries checked in part, past the cap (CAP=)" if partial.any?
        listed(partial) { |run| "  #{where(run)}" }

        refused = report.runs.select(&:refusal)
        return if refused.empty?

        say "not tried: #{refused.size} queries (#{refused.group_by(&:refusal).map { |reason, runs| "#{reason}: #{runs.size}" }.join(', ')})"
        listed(refused.uniq { |run| [ run.dataset, run.shape, run.refusal ] }) { |run| "  #{run.dataset} · #{run.shape}: #{run.refusal}" }
      end

      def verdict(report)
        say ""
        if report.failed?
          unfiltered = report.runs.sum { |run| run.unlisted.size }
          say "FAILED: #{report.leaks.size} rows of another tenant read, #{unfiltered} tables read with no tenant filter"
        else
          say "OK: no row of another tenant in #{report.runs.size - report.runs.count(&:refusal)} queries"
        end
      end

      def where(run) = "#{run.dataset} · #{run.shape} · as #{@config.tenant_model_name} #{run.tenant}"

      def listed(items)
        items.first(MAX_LINES).each { |item| say yield(item) }
        say "  … and #{items.size - MAX_LINES} more" if items.size > MAX_LINES
      end

      def say(line) = @out.puts(line)

      def fail_with(message)
        @out.puts("DataTeller: #{message}")
        1
      end
    end
  end
end
