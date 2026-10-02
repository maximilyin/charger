defmodule Charger.Prices.Schedule do
  @moduledoc """
  Reads a ministry timetable conservatively.

  A station is 24 hours or closed only when every part of the text matches a
  day range and a clock range. Anything else stays unknown, so the raw text is
  shown without a badge.
  """

  @days %{"l" => 1, "m" => 2, "x" => 3, "j" => 4, "v" => 5, "s" => 6, "d" => 7}
  @part ~r/\A\s*([LMXJVSD])(?:\s*-\s*([LMXJVSD]))?\s*:\s*(.+?)\s*\z/i

  def status(schedule, %DateTime{} = at) do
    status(schedule, Date.day_of_week(DateTime.to_date(at)), at.hour * 60 + at.minute)
  end

  def status(nil, _day, _minute), do: :unknown
  def status("", _day, _minute), do: :unknown

  def status(schedule, day, minute) when is_binary(schedule) and day in 1..7 do
    parts =
      schedule
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(parts, &parse_part/1)

    cond do
      parts == [] or Enum.any?(parsed, &is_nil/1) ->
        :unknown

      true ->
        windows =
          Enum.flat_map(parsed, fn {days, hours} ->
            if day in days, do: hours, else: []
          end)

        cond do
          windows == [] -> :closed
          Enum.any?(windows, &(&1 == :all_day)) -> :open_24h
          open_now?(windows, minute) -> :open
          true -> :closed
        end
    end
  end

  def display(nil), do: ""
  def display(""), do: ""

  def display(schedule) when is_binary(schedule) do
    parts =
      schedule
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(parts, &parse_part/1)

    cond do
      parts == [] or Enum.any?(parsed, &is_nil/1) -> schedule
      round_the_clock?(parsed) -> "24H"
      same_hours_every_day?(parsed) -> hours_text(parsed)
      true -> schedule
    end
  end

  def to_madrid(%DateTime{} = utc) do
    DateTime.add(utc, if(eu_dst?(utc), do: 7200, else: 3600), :second)
  end

  defp parse_part(part) do
    case Regex.run(@part, part) do
      [_, start, stop, hours] ->
        case parse_hours(hours) do
          nil -> nil
          windows -> {days(start, stop), windows}
        end

      _ ->
        nil
    end
  end

  defp days(start, stop) do
    first = Map.fetch!(@days, String.downcase(start))

    case blank(stop) do
      nil ->
        [first]

      last ->
        span(first, Map.fetch!(@days, String.downcase(last)))
    end
  end

  defp span(first, last) when first <= last, do: Enum.to_list(first..last)
  defp span(first, last), do: Enum.to_list(first..7) ++ Enum.to_list(1..last)

  defp parse_hours(text) do
    windows =
      text
      |> String.split(~r/\s+y\s+/iu)
      |> Enum.map(&parse_window/1)

    if windows == [] or Enum.any?(windows, &is_nil/1), do: nil, else: windows
  end

  defp parse_window(text) do
    compact = text |> String.trim() |> String.replace(~r/[[:space:]]/u, "") |> String.upcase()

    cond do
      compact in ["24H", "24HORAS"] ->
        :all_day

      true ->
        case Regex.run(~r/\A(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})\z/, compact) do
          [_, h1, m1, h2, m2] ->
            with {:ok, start} <- minutes(String.to_integer(h1), String.to_integer(m1)),
                 {:ok, stop} <- minutes(String.to_integer(h2), String.to_integer(m2)) do
              window(start, stop)
            else
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp window(0, stop) when stop >= 23 * 60 + 59, do: :all_day
  defp window(start, stop) when start == stop, do: :all_day
  defp window(start, 0) when start > 0, do: {:range, start, 24 * 60}
  defp window(start, stop) when stop < start, do: {:overnight, start, stop}
  defp window(start, stop), do: {:range, start, stop}

  defp minutes(hour, minute) when hour in 0..23 and minute in 0..59, do: {:ok, hour * 60 + minute}
  defp minutes(24, 0), do: {:ok, 24 * 60}
  defp minutes(_hour, _minute), do: :error

  defp round_the_clock?(parsed) do
    covers_every_day?(parsed) and
      Enum.all?(parsed, fn {_days, windows} -> windows == [:all_day] end)
  end

  defp same_hours_every_day?(parsed) do
    windows = Enum.map(parsed, fn {_days, hours} -> hours end)
    covers_every_day?(parsed) and Enum.uniq(windows) == [hd(windows)]
  end

  defp covers_every_day?(parsed) do
    parsed
    |> Enum.flat_map(fn {days, _hours} -> days end)
    |> Enum.uniq()
    |> Enum.sort() == [1, 2, 3, 4, 5, 6, 7]
  end

  defp hours_text([{_days, windows} | _]) do
    Enum.map_join(windows, ", ", &format_window/1)
  end

  defp format_window(:all_day), do: "24H"
  defp format_window({:range, start, 1440}), do: "#{clock(start)}-00:00"
  defp format_window({:range, start, stop}), do: "#{clock(start)}-#{clock(stop)}"
  defp format_window({:overnight, start, stop}), do: "#{clock(start)}-#{clock(stop)}"

  defp clock(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    :io_lib.format("~2..0B:~2..0B", [hours, mins]) |> IO.iodata_to_binary()
  end

  defp open_now?(windows, minute) do
    Enum.any?(windows, fn
      :all_day -> true
      {:range, start, stop} -> minute >= start and minute < stop
      {:overnight, start, stop} -> minute >= start or minute < stop
    end)
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp eu_dst?(utc) do
    start = transition(utc.year, 3)
    stop = transition(utc.year, 10)
    DateTime.compare(utc, start) != :lt and DateTime.compare(utc, stop) == :lt
  end

  defp transition(year, month) do
    date = Date.end_of_month(Date.new!(year, month, 1))
    sunday = Date.add(date, -rem(Date.day_of_week(date), 7))
    DateTime.new!(sunday, ~T[01:00:00], "Etc/UTC")
  end
end
