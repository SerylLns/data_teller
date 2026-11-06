require "rails_helper"
require "open3"

# Run for real, in a separate process in the development environment: the test environment does not reload code.
RSpec.describe "Reloading the declarations in development" do
  let(:file) { Rails.root.join("config/data_teller/zz_written_by_reload_spec.rb") }

  # One work unit of the reloader per step, like one request each.
  let(:script) do
    <<~RUBY
      file = Pathname(#{file.to_s.inspect})
      step = -> { Rails.application.reloader.wrap { } ; print DataTeller.registry.dataset(:clients) ? "present " : "absent " }

      step.call
      file.write("DataTeller.refine('Customer', name: :clients) { roles :admin }")
      step.call
      file.delete
      step.call
    RUBY
  end

  it "picks up a declaration file that was added or removed, with no other file touched" do
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => "development" }, "bundle", "exec", "rails", "runner", script, chdir: Rails.root.to_s)

    expect(status.exitstatus).to eq(0), stderr
    expect(stdout.split).to eq(%w[absent present absent])
  ensure
    file.delete if file.exist?
  end
end
