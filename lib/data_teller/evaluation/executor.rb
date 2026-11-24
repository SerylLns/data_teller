module DataTeller
  module Evaluation
    # Runs a query as the question's role on the question set's tenant and day, for the scorer's same_result. nil when the gem refuses it.
    # No user (ADR 0015): the host's resolvers read its own user model, which the eval cannot build. From a role and a tenant, as the
    # isolation kit runs its queries: the role's catalog, the validator, then the compiler inside the read-only transaction QueryRunner
    # uses, with the same database role and row security.
    class Executor
      def initialize(tenant:, today:, time_zone:, config: DataTeller.config)
        @tenant = tenant
        @time_zone = time_zone
        @config = config
        @now = time_zone.local(today.year, today.month, today.day, 12)
      end

      def call(question, query)
        catalog = Catalog.for(question.role)
        return nil unless query["intent"] == "answer" && QueryValidator.new(catalog).call(query).ok?

        run(catalog, query).rows
      rescue Compiler::Refused, ActiveRecord::StatementInvalid, ReadOnlyExecution::OutOfTime
        nil
      end

      private

      def run(catalog, query)
        model = catalog.dataset(query["dataset"]).model_name.constantize
        ReadOnlyExecution.run(model, timeout: @config.query_timeout, role: @config.database_role,
                                     tenant_id: (@tenant.id if @config.row_security)) do
          Compiler.new(catalog: catalog, tenant: @tenant, time_zone: @time_zone, now: @now).call(query).execute
        end
      end
    end
  end
end
