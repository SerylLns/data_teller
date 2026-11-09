require_relative "lib/data_teller/version"

Gem::Specification.new do |spec|
  spec.name        = "data_teller"
  spec.version     = DataTeller::VERSION
  spec.authors     = [ "Seryl" ]
  spec.email       = [ "contact@seryl.dev" ]
  spec.summary     = "Let end users ask questions about their own data in plain language, without LLM-written SQL."
  spec.description = "A mountable Rails engine for multi-tenant apps: an LLM fills a structured query validated against developer declarations, compiled to ActiveRecord with the tenant scope injected."
  spec.license     = "MIT"
  spec.homepage    = "https://github.com/SerylLns/data_teller"
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  # Data.define needs 3.2, while Rails 7.2 still allows 3.1: without this the gem would install and then crash at load.
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "rails", ">= 7.2.2.2"
  spec.add_dependency "json_schemer", "~> 2.0"
end
