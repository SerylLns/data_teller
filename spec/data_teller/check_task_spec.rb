require "rails_helper"
require "open3"

# Run for real, in a separate process: under the default :raise, an in-process spec with a stubbed :environment task
# would hide the fact that the boot raises before the task gets to report anything.
RSpec.describe "rake data_teller:check" do
  let(:dummy) { Rails.root }
  let(:broken_file) { dummy.join("config/data_teller/zz_broken_by_check_task_spec.rb") }

  def run_task
    Open3.capture3({ "RAILS_ENV" => "test" }, "bundle", "exec", "rake", "data_teller:check", chdir: dummy.to_s)
  end

  it "reports the declared datasets and exits 0 when the configuration is valid" do
    stdout, _stderr, status = run_task

    expect(stdout).to include("DataTeller: OK (2 datasets: customers, orders)")
    expect(status.exitstatus).to eq(0)
  end

  it "exits 1 and prints every problem itself when the configuration is invalid" do
    broken_file.write(<<~RUBY)
      DataTeller.refine "Invoice" do
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
end
