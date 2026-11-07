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

  describe "#compared" do
    def compared(range, mode = "previous_period")
      result = described_class.new(time_zone: utc, now: now).compared(range, mode)
      [ result.current, result.previous ]
    end

    {
      "yesterday" => [ %w[2026-11-03 2026-11-04], %w[2026-11-02 2026-11-03] ],
      "last_week" => [ %w[2026-10-26 2026-11-02], %w[2026-10-19 2026-10-26] ],
      "last_month" => [ %w[2026-10-01 2026-11-01], %w[2026-09-01 2026-10-01] ],
      "last_quarter" => [ %w[2026-07-01 2026-10-01], %w[2026-04-01 2026-07-01] ],
      "last_year" => [ %w[2025-01-01 2026-01-01], %w[2024-01-01 2025-01-01] ],
      "next_week" => [ %w[2026-11-09 2026-11-16], %w[2026-11-02 2026-11-09] ]
    }.each do |relative, (current, previous)|
      it "steps #{relative} back by its own unit" do
        expect(compared({ "relative" => relative })).to eq([ days(*current), days(*previous) ])
      end
    end

    # Comparing 4 days of November with all of October would always look like a collapse.
    {
      "today" => [ %w[2026-11-04 2026-11-05], %w[2026-11-03 2026-11-04] ],
      "this_week" => [ %w[2026-11-02 2026-11-05], %w[2026-10-26 2026-10-29] ],
      "this_month" => [ %w[2026-11-01 2026-11-05], %w[2026-10-01 2026-10-05] ],
      "this_quarter" => [ %w[2026-10-01 2026-11-05], %w[2026-07-01 2026-08-05] ],
      "this_year" => [ %w[2026-01-01 2026-11-05], %w[2025-01-01 2025-11-05] ]
    }.each do |relative, (current, previous)|
      it "stops #{relative} at today, on both sides, while it is in progress" do
        expect(compared({ "relative" => relative })).to eq([ days(*current), days(*previous) ])
      end
    end

    it "does not stop a period that is over or has not started" do
      expect(compared({ "relative" => "last_month" }).first).to eq(days("2026-10-01", "2026-11-01"))
      expect(compared({ "relative" => "next_month" }).first).to eq(days("2026-12-01", "2027-01-01"))
    end

    it "steps the last N units back by N" do
      expect(compared({ "last" => { "n" => 7, "unit" => "day" } }).last).to eq(days("2026-10-22", "2026-10-29"))
      expect(compared({ "last" => { "n" => 2, "unit" => "week" } }).last).to eq(days("2026-10-08", "2026-10-22"))
      expect(compared({ "last" => { "n" => 3, "unit" => "month" } }).last).to eq(days("2026-05-05", "2026-08-05"))
      expect(compared({ "last" => { "n" => 1, "unit" => "year" } }).last).to eq(days("2024-11-05", "2025-11-05"))
    end

    it "steps a day and a range back by their length" do
      expect(compared({ "on" => "2024-03-01" }).last).to eq(days("2024-02-29", "2024-03-01"))
      expect(compared({ "between" => { "from" => "2024-01-11", "to" => "2024-01-20" } }).last).to eq(days("2024-01-01", "2024-01-11"))
    end

    it "takes the same dates a year earlier with previous_year" do
      expect(compared({ "relative" => "last_month" }, "previous_year").last).to eq(days("2025-10-01", "2025-11-01"))
      expect(compared({ "relative" => "today" }, "previous_year").last).to eq(days("2025-11-04", "2025-11-05"))
    end

    it "copes with a leap day" do
      expect(compared({ "on" => "2024-02-29" }, "previous_year").last.first).to eq(Date.new(2023, 2, 28))
    end
  end
end
