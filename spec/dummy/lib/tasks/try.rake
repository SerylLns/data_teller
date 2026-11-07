# Dev tool, for the FAKE data of this dummy app: runs a JSON query as a seeded user and prints the SQL and the result.
#   bundle exec rake "try[Acme,admin]" QUERY='{"version":1,"intent":"answer","dataset":"orders","metric":"count"}'
desc "Run a JSON query on the fake data, e.g. rake \"try[Acme,admin]\" QUERY='{...}' (or the JSON on stdin)"
task :try, [ :account, :role ] => :environment do |_task, args|
  abort("Dev tool, refusing to run in production") if Rails.env.production?

  account = Account.find_by(name: args[:account]) || abort("No account named #{args[:account].inspect}. Run db:seed first?")
  user = account.users.find_by(role: args[:role]) || abort("No #{args[:role].inspect} user in #{account.name}. The seeds have admin, support and member.")
  query = JSON.parse(ENV["QUERY"] || $stdin.read)

  ActiveRecord::Base.logger = Logger.new($stdout, formatter: ->(_, _, _, message) { "#{message}\n" })
  outcome = DataTeller::QueryRunner.call(query, user: user)
  ActiveRecord::Base.logger = nil

  puts "\n#{outcome.status}"
  if outcome.result
    puts outcome.result.columns.join(" | ")
    outcome.result.rows.each { |row| puts row.join(" | ") }
    puts "(truncated)" if outcome.result.truncated
  end
  puts "refused: #{outcome.refusal.reason}" if outcome.refusal
end
