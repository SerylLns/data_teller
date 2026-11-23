module DataTeller
  class CostReport
    # rake data_teller:costs: prints the report, sorted by cost, with the current max_query_cost where it falls. Always exits 0 once
    # it ran: it measures, it does not judge.
    class Command
      def initialize(env: ENV, out: $stdout, config: DataTeller.config)
        @env = env
        @out = out
        @config = config
      end

      def call
        return fail_with("DataTeller is disabled: run rake data_teller:check") unless DataTeller.enabled?

        tenants = IsolationCheck::Command.tenants(@env["TENANTS"], @config.tenant_model_name.constantize)
        return fail_with("no #{@config.tenant_model_name} in this database: there is nothing to measure") if tenants.empty?

        lines = CostReport.new(tenants: tenants, config: @config).call
        print_report(tenants, lines)
        0
      rescue IsolationCheck::Command::Usage => e
        fail_with(e.message)
      end

      private

      def print_report(tenants, lines)
        keys = tenants.map { |tenant| tenant.public_send(tenant.class.primary_key) }
        say "DataTeller query costs: #{@config.tenant_model_name} #{keys.join(', ')} · #{lines.size} queries, each run once with " \
            "EXPLAIN ANALYZE"
        say "max_query_cost: #{@config.max_query_cost || 'not set'} · query_timeout: #{@config.query_timeout} s"
        say ""

        measured, refused = lines.partition(&:cost)
        table(measured.sort_by { |line| [ line.cost, line.ms || Float::INFINITY ] })
        not_measured(refused)

        say ""
        say "One run each, with the cache as it is. Set max_query_cost below the costs where the durations take off, with a margin: " \
            "these queries are simple, real questions combine them. query_timeout stays the net."
      end

      def table(lines)
        say "#{'cost'.rjust(12)}  #{'ms'.rjust(10)}  query"
        threshold = @config.max_query_cost
        lines.each_with_index do |line, index|
          if threshold && line.cost > threshold && (index.zero? || lines[index - 1].cost <= threshold)
            say "  ---- max_query_cost #{threshold}: refused from here ----"
          end
          say "#{format('%.2f', line.cost).rjust(12)}  #{milliseconds(line).rjust(10)}  #{line.dataset} · #{line.shape} · as " \
              "#{@config.tenant_model_name} #{line.tenant}"
        end
      end

      # Stopped by the time budget: longer than it, by how much nobody knows.
      def milliseconds(line) = line.ms ? format("%.2f", line.ms) : "> #{(@config.query_timeout * 1000).round}"

      def not_measured(lines)
        return if lines.empty?

        say ""
        say "not measured: #{lines.size} queries (#{lines.group_by(&:refusal).map { |reason, group| "#{reason}: #{group.size}" }.join(', ')})"
        lines.uniq { |line| [ line.dataset, line.shape, line.refusal ] }.each { |line| say "  #{line.dataset} · #{line.shape}: #{line.refusal}" }
      end

      def say(line) = @out.puts(line)

      def fail_with(message)
        @out.puts("DataTeller: #{message}")
        1
      end
    end
  end
end
