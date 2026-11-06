require "rails_helper"
require "tmpdir"
require "generators/data_teller/install/install_generator"

RSpec.describe DataTeller::Generators::InstallGenerator do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  def run_generator
    described_class.start([], destination_root: @root.to_s, quiet: true)
  end

  let(:config_file) { @root.join("config/data_teller.rb") }

  it "creates the global configuration and the folder for the dataset files" do
    run_generator

    expect(config_file).to be_file
    expect(@root.join("config/data_teller")).to be_directory
  end

  # There is no tenant we could guess: a generated default would make the mandatory check pass for everyone.
  it "does not guess the tenant, so the validator asks for it by name" do
    run_generator

    expect(DataTeller.check(@root).errors).to contain_exactly(/no tenant: declare it/)
  end

  it "generates a file that becomes valid once the tenant is set" do
    run_generator
    config_file.write(config_file.read.gsub(/^  # (c\.tenant do|  model Account|  resolve \{.*|end)$/, "  \\1"))

    expect(DataTeller.check(@root)).to be_ok
  end

  it "never overwrites an existing configuration, even without a terminal to ask" do
    run_generator
    config_file.write("# mine")

    run_generator

    expect(config_file.read).to eq("# mine")
  end

  it "replaces it with an explicit --force" do
    run_generator
    config_file.write("# mine")

    described_class.start([ "--force" ], destination_root: @root.to_s, quiet: true)

    expect(config_file.read).to include("DataTeller.configure")
  end

  it "ships its template in the gem" do
    files = Gem::Specification.load(File.expand_path("../../data_teller.gemspec", __dir__)).files

    expect(files).to include("lib/generators/data_teller/install/templates/data_teller.rb")
  end
end
