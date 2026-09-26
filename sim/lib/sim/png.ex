defmodule Sim.Png do
  @moduledoc """
  A solid-colour PNG, for the pictures the fake Kick hands out (a
  channel's `profile_picture`). Pure; no image library needed.
  """

  @doc "A `size`×`size` PNG of one colour."
  @spec solid(pos_integer(), {byte(), byte(), byte()}) :: binary()
  def solid(size, {r, g, b}) do
    row = [0 | List.duplicate([r, g, b], size)]
    pixels = :zlib.compress(IO.iodata_to_binary(List.duplicate(row, size)))

    IO.iodata_to_binary([
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>,
      chunk("IHDR", <<size::32, size::32, 8, 2, 0, 0, 0>>),
      chunk("IDAT", pixels),
      chunk("IEND", "")
    ])
  end

  @doc "A colour picked from a name, the same every time."
  @spec colour(String.t()) :: {byte(), byte(), byte()}
  def colour(name) do
    <<r, g, b, _::binary>> = :crypto.hash(:md5, name)
    {r, g, b}
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
end
