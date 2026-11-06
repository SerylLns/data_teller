namespace :data_teller do
  # Must run before the environment loads: under the default :raise, the boot would die before this task can report.
  task :defer_boot do
    DataTeller.defer_boot!
  end

  desc "Validate the DataTeller declarations (run it in CI before deploying)"
  task check: %i[defer_boot environment] do
    report = DataTeller.check(Rails.root)
    report.warnings.each { |warning| warn "warning: #{warning}" }

    if report.ok?
      datasets = report.registry.datasets
      puts "DataTeller: OK (#{datasets.size} #{datasets.size == 1 ? 'dataset' : 'datasets'}: #{datasets.map(&:name).join(', ')})"
    else
      warn report.message
      exit 1
    end
  end
end
