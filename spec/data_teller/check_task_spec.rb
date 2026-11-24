require "rails_helper"
require "open3"

# Run for real, in a separate process: under the default :raise, an in-process spec with a stubbed :environment task
# would hide the fact that the boot raises before the task gets to report anything.
RSpec.describe "rake data_teller:check" do
  let(:dummy) { Rails.root }
  let(:broken_file) { dummy.join("config/data_teller/zz_broken_by_check_task_spec.rb") }

  def run_task(env = {})
    Open3.capture3({ "RAILS_ENV" => "test" }.merge(env), "bundle", "exec", "rake", "data_teller:check", chdir: dummy.to_s)
  end

  def boot_and_print_enabled(env = {})
    Open3.capture3({ "RAILS_ENV" => "test" }.merge(env), "bundle", "exec", "rails", "runner", "puts DataTeller.enabled?", chdir: dummy.to_s)
  end

  let(:unreachable_database) { { "DATABASE_URL" => "postgresql://nobody@127.0.0.1:1/none" } }

  it "reports the declared datasets and exits 0 when the configuration is valid" do
    stdout, _stderr, status = run_task

    expect(stdout).to include("DataTeller: OK (11 datasets: coupons, customers, invoices, line_items, orders, products, refunds, reviews, shipments, subscriptions, support_tickets)")
    expect(status.exitstatus).to eq(0)
  end

  it "exits 1 and prints every problem itself when the configuration is invalid" do
    broken_file.write(<<~RUBY)
      DataTeller.refine "Quote" do
        metric :x, median: :a
      end
    RUBY

    stdout, stderr, status = run_task

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("DataTeller configuration is invalid")
    expect(stderr).to match(/zz_broken_by_check_task_spec\.rb:\d+: .*aggregation/)
    expect(stderr).not_to include("rake aborted")
    expect(stdout).not_to include("OK")
  ensure
    broken_file.delete if broken_file.exist?
  end

  # The deadlock this prevents: db:migrate boots the app, so a boot checking columns would refuse to start
  # while the migration that adds the column is waiting to run.
  it "catches a missing column, which the boot deliberately does not look at" do
    broken_file.write("DataTeller.refine('Customer', name: :clients) { roles :admin; tenant_path :account; dimension :nope }")

    boot_stdout, = boot_and_print_enabled
    expect(boot_stdout.strip).to eq("true")

    _stdout, stderr, status = run_task
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("Customer has no column nope")
  ensure
    broken_file.delete if broken_file.exist?
  end

  it "does not need the database to boot" do
    stdout, stderr, status = boot_and_print_enabled(unreachable_database)

    expect(status.exitstatus).to eq(0), stderr
    expect(stdout.strip).to eq("true")
  end

  it "fails when it cannot read the database, without printing connection details" do
    _stdout, stderr, status = run_task(unreachable_database)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("cannot read the database")
    expect(stderr).not_to include("nobody")
  end
end

RSpec.describe "rake data_teller:grants" do
  it "says what to set when no database_role is configured, and prints no SQL" do
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "test" }, "bundle", "exec", "rake", "data_teller:grants", chdir: Rails.root.to_s)

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("set c.database_role")
    expect(stdout).to eq("")
  end
end

RSpec.describe "rake data_teller:eval" do
  def run_task(*args, env: {})
    Open3.capture3({ "RAILS_ENV" => "test" }.merge(env), "bundle", "exec", "rake", *args, chdir: Rails.root.to_s)
  end

  it "scores the perfect model on the working set" do
    stdout, stderr, status = run_task("data_teller:eval[dev]", env: { "LANGUAGES" => "en" })

    expect(status.exitstatus).to eq(0), stderr
    expect(stdout).to include("Score: 100.0% (41/41)")
  end

  it "says what is wrong instead of a stack trace" do
    _stdout, stderr, status = run_task("data_teller:eval[nope]")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("DataTeller: no question set at")
    expect(stderr).not_to include("rake aborted")
  end
end
