require "rails_helper"
require "rake"
require "tmpdir"

RSpec.describe "rake data_teller:check" do
  before(:all) do
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/data_teller_tasks.rake", __dir__)
  end

  before { Rake::Task["data_teller:check"].reenable }
  # Rails.root is stubbed in one example and after hooks run before stubs are removed, hence the explicit path.
  after { DataTeller.boot!(Pathname(File.expand_path("../dummy", __dir__))) }

  it "reports the declared datasets when the configuration is valid" do
    expect { Rake::Task["data_teller:check"].invoke }.to output(/DataTeller: OK \(2 datasets: customers, orders\)/).to_stdout
  end

  it "exits non-zero and prints every problem when it is invalid" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      allow(Rails).to receive(:root).and_return(root)
      DataTeller.reset!

      expect { Rake::Task["data_teller:check"].invoke }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(/no tenant resolver/).to_stderr
    end
  end
end
