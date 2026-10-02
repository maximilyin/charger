defmodule Charger.Prices.ScheduleTest do
  use ExUnit.Case, async: true

  alias Charger.Prices.Schedule

  test "marks an all-week 24H timetable as open all day" do
    assert Schedule.status("L-D: 24H", friday(), 23 * 60) == :open_24h
  end

  test "marks a parsed timetable closed outside its hours" do
    schedule = "L-V: 08:00-21:00; S: 09:00-14:00"

    assert Schedule.status(schedule, friday(), 10 * 60) == :open
    assert Schedule.status(schedule, friday(), 21 * 60) == :closed
    assert Schedule.status(schedule, saturday(), 10 * 60) == :open
    assert Schedule.status(schedule, sunday(), 12 * 60) == :closed
  end

  test "understands a midday break and an overnight range" do
    assert Schedule.status("L-V: 09:00-14:00 y 16:00-19:00", friday(), 15 * 60) == :closed
    assert Schedule.status("L-V: 09:00-14:00 y 16:00-19:00", friday(), 17 * 60) == :open
    assert Schedule.status("L-D: 06:00-02:00", friday(), 1 * 60) == :open
    assert Schedule.status("L-D: 06:00-02:00", friday(), 3 * 60) == :closed
    assert Schedule.status("L-D: 06:00-00:00", friday(), 23 * 60) == :open
    assert Schedule.status("L-D: 06:00-00:00", friday(), 30) == :closed
  end

  test "leaves unusual text without a badge" do
    assert Schedule.status("consultar en estación", friday(), 12 * 60) == :unknown
    assert Schedule.status("", friday(), 12 * 60) == :unknown
    assert Schedule.status(nil, friday(), 12 * 60) == :unknown
  end

  test "shortens a timetable for the table" do
    assert Schedule.display("L-D: 24H") == "24H"
    assert Schedule.display("L-D: 06:00-22:00") == "06:00-22:00"

    assert Schedule.display("L-V: 08:00-21:00; S: 09:00-14:00") ==
             "L-V: 08:00-21:00; S: 09:00-14:00"

    assert Schedule.display("L-D: 09:00-14:00 y 16:00-19:00") == "09:00-14:00, 16:00-19:00"
    assert Schedule.display("consultar") == "consultar"
  end

  test "shifts utc into central european time" do
    winter = DateTime.new!(~D[2026-01-15], ~T[12:00:00], "Etc/UTC")
    summer = DateTime.new!(~D[2026-07-15], ~T[12:00:00], "Etc/UTC")

    assert Schedule.to_madrid(winter) |> DateTime.to_time() == ~T[13:00:00]
    assert Schedule.to_madrid(summer) |> DateTime.to_time() == ~T[14:00:00]
  end

  defp friday, do: 5
  defp saturday, do: 6
  defp sunday, do: 7
end
