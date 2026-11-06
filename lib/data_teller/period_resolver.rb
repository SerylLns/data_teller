require "date"

module DataTeller
  # Turns a `range` of the query into two dates, the end being exclusive, in the tenant's time zone (ADR 0001 D1).
  # Only here: neither the LLM nor a declaration ever computes a date.
  class PeriodResolver
    def initialize(time_zone:, now:)
      @today = now.in_time_zone(time_zone).to_date
    end

    def call(range)
      if range["relative"] then relative(range["relative"])
      elsif range["last"] then last(range["last"])
      elsif range["on"] then single_day(Date.iso8601(range["on"]))
      else between(range["between"])
      end
    end

    private

    def relative(name)
      case name
      when "today" then single_day(@today)
      when "yesterday" then single_day(@today - 1)
      when "tomorrow" then single_day(@today + 1)
      when "this_week" then week(@today)
      when "last_week" then week(@today - 7)
      when "next_week" then week(@today + 7)
      when "this_month" then month(@today)
      when "last_month" then month(@today.prev_month)
      when "next_month" then month(@today.next_month)
      when "this_quarter" then quarter(@today)
      when "last_quarter" then quarter(@today.months_ago(3))
      when "next_quarter" then quarter(@today.months_since(3))
      when "this_year" then year(@today)
      when "last_year" then year(@today.prev_year)
      end
    end

    # Rolling and including today (ADR 0005 D2).
    def last(spec)
      count = spec["n"]
      start =
        case spec["unit"]
        when "day" then @today - (count - 1)
        when "week" then @today - ((count * 7) - 1)
        when "month" then @today.months_ago(count) + 1
        when "year" then @today.years_ago(count) + 1
        end
      [ start, @today + 1 ]
    end

    def between(spec)
      [ Date.iso8601(spec["from"]), Date.iso8601(spec["to"]) + 1 ]
    end

    def single_day(day) = [ day, day + 1 ]
    def week(day) = [ day.beginning_of_week(:monday), day.beginning_of_week(:monday) + 7 ]
    def month(day) = [ day.beginning_of_month, day.beginning_of_month.next_month ]
    def quarter(day) = [ day.beginning_of_quarter, day.beginning_of_quarter.months_since(3) ]
    def year(day) = [ day.beginning_of_year, day.beginning_of_year.next_year ]
  end
end
