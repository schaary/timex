defmodule Timex.DateFormat do
  @moduledoc """
  Date formatting and parsing.

  This module provides an interface and core implementation for converting date
  values into strings (formatting) or the other way around (parsing) according
  to the specified template.

  Multiple template formats are supported, each one provided by a separate
  module. One can also implement custom formatters for use with this module.
  """
  require Record
  alias Timex.DateTime,     as: DateTime
  alias Timex.Date,         as: Date
  alias Timex.Date.Convert, as: DateConvert
  alias Timex.Timezone,     as: Timezone

  @type formatter :: atom | {function, String.t}

  @doc """
  Converts date values to strings according to the given template (aka format string).
  """
  @spec format(DateTime.t, String.t) :: {:ok, String.t} | {:error, String.t}

  def format(%DateTime{} = date, fmt) when is_binary(fmt) do
    format(date, fmt, :default)
  end

  @doc """
  Same as `format/2`, but takes a custom formatter.
  """
  @spec format(DateTime.t, String.t, formatter) :: {:ok, String.t} | {:error, String.t}

  def format(%DateTime{} = date, fmt, formatter) when is_binary(fmt) do
    case tokenize(fmt, formatter) do
      { :ok, parts } ->
        # The following reduce() calls produces a list of date components
        # formatted according to the directives and literal strings in `parts`
        result = Enum.reduce(parts, [], fn
          ({:subfmt, sfmt}, acc) ->
            { :ok, bin } = if is_atom(sfmt) do
              format_predefined(date, sfmt)
            else
              format(date, sfmt, formatter)
            end
            [acc, bin]

          ({dir, fmt}, acc) ->
            arg = format_directive(date, dir)
            [acc, :io_lib.format(fmt, [arg])]

          (bin, acc) when is_binary(bin) ->
            [acc, bin]
        end)
        
        {:ok, result |> List.to_string}

      error -> error
    end
  end

  @doc """
  Raising version of `format/2`. Returns a string with formatted date or
  raises an `ArgumentError`.
  """
  @spec format!(DateTime.t, String.t) :: String.t | no_return

  def format!(%DateTime{} = date, fmt) do
    format!(date, fmt, :default)
  end

  @doc """
  Raising version of `format/3`. Returns a string with formatted date or
  raises an `ArgumentError`.
  """
  @spec format!(DateTime.t, String.t, formatter) :: String.t | no_return

  def format!(%DateTime{} = date, fmt, formatter) do
    case format(date, fmt, formatter) do
      { :ok, result }    -> result
      { :error, reason } -> raise ArgumentError, message: "Bad format: #{reason}"
    end
  end

  @doc """
  Parses the date encoded in `string` according to the template.
  """
  @spec parse(String.t, String.t) :: {:ok, Date.dtz} | {:error, String.t}

  def parse(string, fmt) do
    parse(string, fmt, :default)
  end

  @doc """
  Parses the date encoded in `string` according to the template by using the
  provided formatter.
  """
  @spec parse(String.t, String.t, formatter) :: {:ok, Date.dtz, String.t} | {:error, String.t}

  def parse(string, fmt, formatter) do
    case tokenize(fmt, formatter) do
      { :ok, parts } ->
        case parse_with_parts(string, parts, formatter) do
          { :ok, rest, date_comps } ->
            { :ok, date_with_comps(date_comps), List.to_string(rest) }
          error -> error
        end

      error -> error
    end
  end

  @doc """
  Verifies the validity of the given format string. The default formatter is assumed.

  Returns `:ok` if the format string is clean, `{ :error, <reason> }`
  otherwise.
  """
  @spec validate(String.t) :: :ok | {:error, String.t}

  def validate(fmt) do
    validate(fmt, :default)
  end

  @doc """
  Verifies the validity of the given format string according to the provided
  formatter.

  Returns `:ok` if the format string is clean, `{ :error, <reason> }`
  otherwise.
  """
  @spec validate(String.t, formatter) :: :ok | {:error, String.t}

  def validate(fmt, formatter) do
    case tokenize(fmt, formatter) do
      { :ok, _ } -> :ok
      error -> error
    end
  end

  #########################
  ### Private functions ###

  # Takes a directive (atom) and extracts the corresponding component from the
  # date
  defp format_directive(%DateTime{:year => year, :month => month, :day => day, :hour => hour, :minute => min, :second => sec} = date, dir) do
    start_of_year = Date.from({year,1,1})
    {iso_year, iso_week} = Date.iso_week(date)

    daynum = fn date ->
      1 + Date.diff(start_of_year, date, :days)
    end

    get_week_no = fn jan1weekday ->
      first_monday = rem(7 - jan1weekday, 7) + 1
      div(Date.day(date) - first_monday + 7, 7)
    end

    case dir do
      :year      -> year
      :year2     -> rem(year, 100)
      :century   -> div(year, 100)
      :iso_year  -> iso_year
      :iso_year2 -> rem(iso_year, 100)

      :month     -> month
      :mshort    -> month |> Date.month_shortname
      :mfull     -> month |> Date.month_name

      :day       -> day
      :oday      -> daynum.(date)
      :wday_mon  -> Date.weekday(date)
      :wday_sun  -> rem(Date.weekday(date), 7)
      :wdshort   -> Date.weekday(date) |> Date.day_shortname
      :wdfull    -> Date.weekday(date) |> Date.day_name

      :iso_week  -> iso_week
      :week_mon  -> get_week_no.(Date.weekday(start_of_year) - 1)
      :week_sun  -> get_week_no.(rem Date.weekday(start_of_year), 7)

      :hour24    -> hour
      :hour12 when hour in [0, 12] -> 12
      :hour12    -> rem(hour, 12)
      :min       -> min
      :sec       -> sec
      :sec_epoch -> Date.to_secs(date)
      :am        -> if hour < 12 do "am" else "pm" end
      :AM        -> if hour < 12 do "AM" else "PM" end

      :zname ->
        {_,_,{_,tz_name}} = DateConvert.to_gregorian(date)
        tz_name
      :zoffs ->
        {_,_,{tz_offset,_}} = DateConvert.to_gregorian(date)
        { sign, hour, min, _ } = split_tz(tz_offset)
        :io_lib.format("~s~2..0B~2..0B", [sign, hour, min])
      :zoffs_colon ->
        {_,_,{tz_offset,_}} = DateConvert.to_gregorian(date)
        { sign, hour, min, _ } = split_tz(tz_offset)
        :io_lib.format("~s~2..0B:~2..0B", [sign, hour, min])
      :zoffs_sec ->
        {_,_,{tz_offset,_}} = DateConvert.to_gregorian(date)
        :io_lib.format("~s~2..0B:~2..0B:~2..0B", Tuple.to_list(split_tz(tz_offset)))
    end
  end

  ## ISO 8601 ##

  defp format_predefined(date, :"ISOz") do
    format_iso(Date.universal(date), "Z")
  end

  defp format_predefined(date, :"ISO") do
    { _, _, {offset,_} } = DateConvert.to_gregorian(date)

    { sign, hrs, min, _ } = split_tz(offset)
    tz = :io_lib.format("~s~2..0B~2..0B", [sign, hrs, min])

    format_iso(date, tz)
  end

  defp format_predefined(date, :"ISOdate") do
    %DateTime{:year => year, :month => month, :day => day} = Date.universal(date)
    :io_lib.format("~4..0B-~2..0B-~2..0B", [year, month, day])
    |> wrap
  end

  defp format_predefined(date, :"ISOtime") do
    %DateTime{:hour => hour, :minute => min, :second => sec} = Date.universal(date)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [hour, min, sec])
    |> wrap
  end

  defp format_predefined(date, :"ISOweek") do
    {year, week} = Date.iso_week(date)
    :io_lib.format("~4..0B-W~2..0B", [year, week])
    |> wrap
  end

  defp format_predefined(date, :"ISOweek-day") do
    {year, week, day} = Date.iso_triplet(date)
    :io_lib.format("~4..0B-W~2..0B-~B", [year, week, day])
    |> wrap
  end

  defp format_predefined(date, :"ISOord") do
    %DateTime{:year => year} = date
    day_no = date |> Date.universal |> Date.day
    :io_lib.format("~4..0B-~3..0B", [year, day_no]) |> wrap
  end

  ## RFC 1123 ##

  defp format_predefined(date, :"RFC1123") do
    { _, _, {_,tz_name} } = DateConvert.to_gregorian(date)
    format_rfc(date, {:name, tz_name})
  end

  defp format_predefined(date, :"RFC1123z") do
    { _, _, {tz_offset,_} } = DateConvert.to_gregorian(date)
    format_rfc(date, {:offset, tz_offset})
  end

  ## Other common formats ##

  # This is similar to ISO, but using xx:xx format for time zone offset (as
  # opposed to xxxx)
  defp format_predefined(date, :"RFC3339") do
    { _, _, {offset,_} } = DateConvert.to_gregorian(date)
    tz = if offset == 0 do
      "Z"
    else
      { sign, hrs, min, _ } = split_tz(offset)
      :io_lib.format("~s~2..0B:~2..0B", [sign, hrs, min])
    end
    format_iso(date, tz)
  end

  #ANSIC       = "Mon Jan _2 15:04:05 2006"
  defp format_predefined(%DateTime{:year => year, :month => month, :day => day, :hour => hour, :minute => min, :second => sec} = date, :"ANSIC") do
    day_name = Date.weekday(date) |> Date.day_shortname
    month_name = month |> Date.month_shortname

    fstr = "~s ~s ~2.. B ~2..0B:~2..0B:~2..0B ~4..0B"
    :io_lib.format(fstr, [day_name, month_name, day, hour, min, sec, year])
    |> wrap
  end

  #UnixDate    = "Mon Jan _2 15:04:05 MST 2006"
  defp format_predefined(%DateTime{:year => year, :month => month, :day => day, :hour => hour, :minute => min, :second => sec} = date, :"UNIX") do
    day_name = Date.weekday(date) |> Date.day_shortname
    month_name = month |> Date.month_shortname

    {_,_,{_,tz_name}} = DateConvert.to_gregorian(date)

    fstr = "~s ~s ~2.. B ~2..0B:~2..0B:~2..0B #{tz_name} ~4..0B"
    :io_lib.format(fstr, [day_name, month_name, day, hour, min, sec, year])
    |> wrap
  end

  #Kitchen     = "3:04PM"
  defp format_predefined(%DateTime{:hour => hour, :minute => min}, :"kitchen") do
    am = if hour < 12 do "AM" else "PM" end
    hour = if hour in [0, 12] do 12 else rem(hour, 12) end
    :io_lib.format("~B:~2..0B~s", [hour, min, am])
    |> wrap
  end

  ### Helper functions used by format_predefined ###

  defp format_iso(%DateTime{:year => y, :month => m, :day => d, :hour => h, :minute => min, :second => sec}, tz) do
    :io_lib.format(
        "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B~s",
        [y, m, d, h, min, sec, tz]
    ) |> wrap
  end

  defp format_rfc(%DateTime{:year => year, :month => month, :day => day, :hour => hour, :minute => min, :second => sec} = date, tz) do
    day_name = Date.weekday(date) |> Date.day_shortname
    month_name = month |> Date.month_shortname
    fstr = case tz do
      { :name, tz_name } ->
        if tz_name == "UTC" do
          tz_name = "GMT"
        end
        "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B #{tz_name}"
      { :offset, tz_offset } ->
        { sign, tz_hrs, tz_min, _ } = split_tz(tz_offset)
        tz_spec = :io_lib.format("~s~2..0B~2..0B", [sign, tz_hrs, tz_min])
        "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B #{tz_spec}"
    end
    :io_lib.format(fstr, [day_name, day, month_name, year, hour, min, sec])
    |> wrap
  end

  defp split_tz(offset) do
    sign = if offset >= 0 do "+" else "-" end
    offset = abs(offset)
    hrs = trunc(offset)
    min = trunc((offset - hrs) * 60)
    sec = trunc((offset - hrs - min) * 3600)
    { sign, hrs, min, sec }
  end

  defp wrap(formatted) do
    { :ok, IO.iodata_to_binary(formatted) }
  end

  ### Private functions for parsing ###

  # This is a mirror of format/3.
  defp parse_with_parts(string, parts, formatter) do
    try do
      {rest, comps} = Enum.reduce(parts, {String.to_char_list(string), []}, fn
        ({:subfmt, sfmt}, {string, acc}) ->
          case tokenize(sfmt, formatter) do
            { :ok, sub_parts } ->
              case parse_with_parts("#{string}", sub_parts, formatter) do
                { :ok, rest, date_comps } ->
                  {rest, merge_comps(acc, date_comps)}
                error -> raise error
              end
            error -> raise error
          end

        ({dir, fmt}, {string, acc}) ->
          case parse_directive(string, dir, fmt) do
            { :ok, comp, rest } -> {rest, merge_comps(acc, comp)}
            { :error, reason }  -> throw reason
          end

        (bin, {string, acc}) when is_binary(bin) ->
          # A binary is matched literally
          case fread(String.to_char_list(bin), string) do
            { :ok, [], rest }  -> {rest, acc}
            { :more, _, _, _ } -> throw "unexpected end of input"
            { :error, reason } -> throw reason
          end
      end)
      {:ok, rest, comps}
    catch
      :throw, reason ->
        { :error, reason }
    end
  end

  # parse_directive() extracts a single token from the input string and
  # converts it into an intermediate form (using read_token) that will be used
  # later to build the date

  defp parse_directive(string, dir, "~B") do
    read_token(string, dir, '~d')
  end

  defp parse_directive(string, dir, "~s") do
    read_token(string, dir, '~s')
  end

  defp parse_directive(string, dir, fmt) do
    case Regex.run(~r/^~(\d+)\.\.[0 ]B$/, fmt) do
      [_, <<num>>] ->
        read_token(string, dir, [?~, num, ?d])
      _ ->
        { :error, fmt }
    end
  end

  # Converts a formatting directive into intermediate date component (to be
  # used when building the date later)
  defp read_token(string, dir, native_fmt) do
    %DateTime{:year => year} = Date.local
    century = div(year, 100)

    case fread(native_fmt, string) do
      { :ok, [read], rest } ->
        comp = case dir do
          # FIXME: year number has to be in the range 0..9999
          :year      -> [century: div(read,100), year2: rem(read,100)]
          :year2     ->
            # assuming current century
            [century: century, year2: read]
          :century   -> [century: read]
          :iso_year  -> [iso_year: read]
          :iso_year2 ->
            # assuming current century
            [iso_year: century*100 + read]
          :month     -> [month: read]
          :mshort    -> [month: Date.month_to_num("#{read}")]
          :mfull     -> [month: Date.month_to_num("#{read}")]
          :day       -> [day: read]
          :oday      -> [oday: read]
          :wday_mon  -> [wday: read]
          :wday_sun  -> [wday: if read == 0 do 7 else read end]
          :wdshort   -> [wday: Date.day_to_num("#{read}")]
          :wdfull    -> [wday: Date.day_to_num("#{read}")]
          :iso_week  -> [iso_week: read]
          :week_mon  -> [week: read]
          :week_sun  -> [week: read]  # FIXME
          :hour24    -> [hour: read]
          :hour12    -> [hour: read]
          :am        -> [am: is_am(read)]
          :AM        -> [am: is_am(read)]
          :pm        -> [am: is_am(read)]
          :PM        -> [am: is_am(read)]
          :min       -> [min: read]
          :sec       -> [sec: read]
          :sec_epoch -> [osec: read]
          :zname     -> [tz: Timezone.get("#{read}")]
          :zoffs     -> [tz: Timezone.get("#{read}")]
          :zoffs_colon ->
            raise ArgumentError, message: "Unsupported parse directive :zoffs_colon"
          :zoffs_sec ->
            raise ArgumentError, message: "Unsupported parse directive :zoffs_sec"
        end
        { :ok, comp, rest }

      { :more, _, _, _ } -> throw "unexpected end of input"
      { :error, reason } -> throw reason
    end
  end

  # Merge any repeating intermediate components. The most recent one wins.
  defp merge_comps(c1, c2) do
    Keyword.merge(c1, c2)
  end

  # Build the resulting date from the accumulated intermediate components.
  # Currently, this does not handle all input strings correctly. For instance,
  # "PM 1" won't work.
  Record.defrecordp :tmpdate, year: 0, month: 1, day: 1, hour: 0, min: 0, sec: 0, tz: Timezone.get(:utc)
  defp date_with_comps(comps) do
    # valid comps include:
    # * century
    # * year2
    # * iso_year
    # * month
    # * wday
    # * week
    # * iso_week
    # * day
    # * oday
    # * hour
    # * min
    # * sec
    # * osec
    # * am
    # * tz

    date = Enum.reduce comps, tmpdate(), fn
      {:century, num}, tmpdate(year: y)=acc ->
        tmpdate(acc, year: y + num*100)
      {:year2, num}, tmpdate(year: y)=acc ->
        tmpdate(acc, year: y + num)
      {:iso_year, _num}, tmpdate() ->
        raise ArgumentError, message: "Unsupported parse directive :iso_year"
      {:month, num}, tmpdate()=acc ->
        tmpdate(acc, month: num)
      {:day, num}, tmpdate()=acc ->
        tmpdate(acc, day: num)
      {:hour, num}, tmpdate()=acc ->
        tmpdate(acc, hour: num)
      {:am, false}, tmpdate(hour: h)=acc ->
        tmpdate(acc, hour: h + 12)
      {:am, true}, tmpdate(hour: 12)=acc ->
        tmpdate(acc, hour: 0)
      {:am, true}, tmpdate()=acc ->
        acc
      {:min, num}, tmpdate()=acc ->
        tmpdate(acc, min: num)
      {:sec, num}, tmpdate()=acc ->
        tmpdate(acc, sec: num)
      {:tz, tz}, tmpdate()=acc ->
        tmpdate(acc, tz: tz)
      {:wday, _}, acc ->
        acc
    end

    Date.from({{tmpdate(date, :year), tmpdate(date, :month), tmpdate(date, :day)},
               {tmpdate(date, :hour), tmpdate(date, :min), tmpdate(date, :sec)}}, tmpdate(date, :tz))
  end

  defp is_am(x) when x in ['am', 'AM'], do: true
  defp is_am(x) when x in ['pm', 'PM'], do: false

  ######################################################

  ### Working with formatters ###

  defp tokenize(fmt, :default) when is_binary(fmt) do
    do_tokenize(fmt, {&Timex.DateFormat.Default.process_directive/1, "{"})
  end

  defp tokenize(fmt, :strftime) when is_binary(fmt) do
    do_tokenize(fmt, {&Timex.DateFormat.Strftime.process_directive/1, "%"})
  end

  defp tokenize(fmt, {formatter, pat})
        when is_binary(fmt)
         and is_function(formatter)
         and is_binary(pat) do
    do_tokenize(fmt, {formatter, pat})
  end

  # do_tokenize() returns { :ok, parts } where parts is a list of formatting
  # directives and literal strings

  defp do_tokenize(str, formatter) do
    do_tokenize(str, formatter, 0, [], [])
  end

  defp do_tokenize("", _, _, parts, acc) do
    { :ok, List.flatten([parts, List.to_string(acc)]) }
  end

  defp do_tokenize(str, {formatter, pat}=fmt, pos, parts, acc) do
    patsize = byte_size(pat)
    case str do
      <<^pat :: [binary, size(patsize)], rest :: binary>> ->
        case formatter.(rest) do
          { :skip, length } ->
            <<skip :: [binary, size(length)], rest :: binary>> = rest
            do_tokenize(rest, fmt, pos + length + 1, parts, [acc,skip])

          { :ok, dir, length } ->
            new_parts = [parts, List.to_string(acc), dir]
            <<_ :: [binary, size(length)], rest :: binary>> = rest
            do_tokenize(rest, fmt, pos + length, new_parts, [])

          { :error, reason } ->
            { :error, "at #{pos}: #{reason}" }
        end
      _ ->
        <<c :: utf8, rest :: binary>> = str
        do_tokenize(rest, fmt, pos+1, parts, [acc, c])
    end
  end

  defp fread('~s', charlist), do: fread("~s", charlist)
  defp fread("~s", charlist) do
    [[{start, finish}]|_] = Regex.scan(~r/\w+/u, "#{charlist}", return: :index)
    read      = Enum.take(charlist, start + finish)
    remainder = Enum.drop(charlist, start + finish)
    {:ok, [read], remainder}
  end
  defp fread(native_fmt, charlist) do
    :io_lib.fread(native_fmt, charlist)
  end
end
