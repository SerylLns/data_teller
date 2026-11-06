namespace :data_teller do
  desc "Validate the DataTeller declarations (run it in CI before deploying)"
  task check: :environment do
    report = DataTeller.check(Rails.root)
    report.warnings.each { |warning| warn "warning: #{warning}" }

    if report.ok?
      datasets = DataTeller.registry.datasets
      puts "DataTeller: OK (#{datasets.size} #{datasets.size == 1 ? 'dataset' : 'datasets'}: #{datasets.map(&:name).join(', ')})"
    else
      warn report.message
      exit 1
    end
  end
end
