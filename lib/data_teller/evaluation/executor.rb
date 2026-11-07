module DataTeller
  module Evaluation
    # Runs a query as the question's role on the question set's tenant and day, for the scorer's same_result. Read-only like any
    # query: it goes through QueryRunner. nil when the gem refuses it.
    class Executor
      User = Struct.new(:account, :roles)

      def initialize(tenant:, today:, time_zone:)
        @tenant = tenant
        @now = time_zone.local(today.year, today.month, today.day, 12)
      end

      def call(question, query)
        outcome = QueryRunner.call(query, user: User.new(@tenant, [ question.role ]), now: @now)
        outcome.status == :answered ? outcome.result.rows : nil
      end
    end
  end
end
