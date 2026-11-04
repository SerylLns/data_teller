require_relative "lib/data_teller/version"

Gem::Specification.new do |spec|
  spec.name        = "data_teller"
  spec.version     = DataTeller::VERSION
  spec.authors     = [ "Seryl" ]
  spec.email       = [ "lnsseryl@gmail.com" ]
  spec.summary     = "Let end users ask questions about their own data in plain language, without LLM-written SQL."
  spec.description = "A mountable Rails engine for multi-tenant apps: an LLM fills a structured query validated against developer declarations, compiled to ActiveRecord with the tenant scope injected."
  spec.license     = "MIT"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.2.2.2"
end
