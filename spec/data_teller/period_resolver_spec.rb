require "rails_helper"

RSpec.describe DataTeller::PeriodResolver do
  # A Wednesday. Paris is already on 2026-11-05 while UTC is still on the 4th, late at night.
  let(:now) { Time.utc(2026, 11, 4, 23, 30) }
  let(:paris) { ActiveSupport::TimeZone["Europe/Paris"] }
  let(:utc) { ActiveSupport::TimeZone["UTC"] }

  def resolve(range, zone = utc) = described_class.new(time_zone: zone, now: now).call(range)
  def days(from, to) = [ Date.parse(from), Date.parse(to) ]

  it "resolves today in the tenant's time zone, not the server's" do
    expect(resolve({ "relative" => "today" }, utc)).to eq(days("2026-11-04", "2026-11-05"))
    expect(resolve({ "relative" => "today" }, paris)).to eq(days("2026-11-05", "2026-11-06"))
  end

  {
    "yesterday" => %w[2026-11-03 2026-11-04],
    "tomorrow" => %w[2026-11-05 2026-11-06],
    "this_week" => %w[2026-11-02 2026-11-09],
    "last_week" => %w[2026-10-26 2026-11-02],
    "next_week" => %w[2026-11-09 2026-11-16],
    "this_month" => %w[2026-11-01 2026-12-01],
    "last_month" => %w[2026-10-01 2026-11-01],
    "next_month" => %w[2026-12-01 2027-01-01],
    "this_quarter" => %w[2026-10-01 2027-01-01],
    "last_quarter" => %w[2026-07-01 2026-10-01],
    "next_quarter" => %w[2027-01-01 2027-04-01],
    "this_year" => %w[2026-01-01 2027-01-01],
    "last_year" => %w[2025-01-01 2026-01-01]
  }.each do |relative, (from, to)|
    it "resolves #{relative}, with an exclusive end" do
      expect(resolve({ "relative" => relative })).to eq(days(from, to))
    end
  end

  {
    { "n" => 7, "unit" => "day" } => %w[2026-10-29 2026-11-05],
    { "n" => 1, "unit" => "day" } => %w[2026-11-04 2026-11-05],
    { "n" => 2, "unit" => "week" } => %w[2026-10-22 2026-11-05],
    { "n" => 3, "unit" => "month" } => %w[2026-08-05 2026-11-05],
    { "n" => 1, "unit" => "year" } => %w[2025-11-05 2026-11-05]
  }.each do |last, (from, to)|
    it "resolves the last #{last['n']} #{last['unit']}, today included" do
      expect(resolve({ "last" => last })).to eq(days(from, to))
    end
  end

  it "resolves a single day" do
    expect(resolve({ "on" => "2024-02-29" })).to eq(days("2024-02-29", "2024-03-01"))
  end

  it "includes both ends of between" do
    expect(resolve({ "between" => { "from" => "2024-01-01", "to" => "2024-01-31" } })).to eq(days("2024-01-01", "2024-02-01"))
  end
end
