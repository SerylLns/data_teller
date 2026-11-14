require "rails_helper"

# The note on hidden groups (ADR 0012 D3): how many, never which.
RSpec.describe "data_teller/questions/_outcome", type: :view do
  def render_result(rows:, suppressed:)
    result = DataTeller::Plan::Result.new(columns: %w[city count], rows: rows, truncated: false, period: nil, compared_period: nil,
                                          suppressed: suppressed)
    outcome = DataTeller::QueryRunner::Outcome.new(status: :answered, query: { "dataset" => "customers", "metric" => "count" },
                                                   result: result, refusal: nil, trace: nil)
    render partial: "data_teller/questions/outcome", locals: { outcome: outcome }
  end

  it "says how many groups are hidden, under the ones shown" do
    render_result(rows: [ [ "Paris", 4 ] ], suppressed: 2)

    expect(rendered).to include("<td>Paris</td>", "2 groups are not shown")
  end

  it "does not say nothing matches when every group is hidden" do
    render_result(rows: [], suppressed: 1)

    expect(rendered).to include("1 group is not shown")
    expect(rendered).not_to include("Nothing matches")
  end

  it "says nothing about hiding when nothing is hidden" do
    render_result(rows: [], suppressed: 0)

    expect(rendered).to include("Nothing matches")
    expect(rendered).not_to include("not shown")
  end
end
