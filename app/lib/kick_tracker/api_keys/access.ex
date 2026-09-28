defmodule KickTracker.ApiKeys.Access do
  @moduledoc """
  What an API key may reach (project.md §13.10). Pure.

  A channel is reached **fully**, **live** (only "now", for a channel shown
  only while live) or **not at all**:

    * an admin key reaches every channel fully, hidden ones included;
    * a regular key reaches the channels in its scope (all of them, or
      those it lists and those in the groups it lists): a public one
      fully, a live-only one live, a hidden one never.

  Within that, a regular key reads only the kinds of data its scopes name.
  """

  alias KickTracker.Series.Resolution

  @scopes ~w(channels live viewers chat followers support categories)

  @doc "The scopes a regular key may be given."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @type access :: :full | :live | :none

  @doc "How far a key reaches a channel (`group_ids`: the groups the channel is in)."
  @spec channel_access(map(), map(), [integer()]) :: access()
  def channel_access(%{admin: true}, _channel, _group_ids), do: :full

  def channel_access(key, %{id: id, visibility: visibility}, group_ids) do
    in_scope? =
      key.all_channels or id in key.channel_ids or Enum.any?(group_ids, &(&1 in key.group_ids))

    case {in_scope?, visibility} do
      {true, :public} -> :full
      {true, :live_only} -> :live
      _ -> :none
    end
  end

  @doc """
  Whether a key may read `scope` of a channel it reaches with `access`.
  `"live"` (now) needs any access; every other scope needs full access;
  `"chat_log"` is for admin keys only.
  """
  @spec can?(map(), access(), String.t()) :: boolean()
  def can?(_key, :none, _scope), do: false
  def can?(%{admin: true}, _access, _scope), do: true
  def can?(_key, _access, "chat_log"), do: false
  def can?(key, _access, "live"), do: "live" in key.scopes
  def can?(key, :full, scope), do: scope in key.scopes
  def can?(_key, :live, _scope), do: false

  @doc "Whether a channel belongs in the key's list of channels."
  @spec listed?(map(), access()) :: boolean()
  def listed?(key, access), do: can?(key, access, "channels") or can?(key, access, "live")

  @doc """
  The range a key may read: `from` moved forward to `history_days` before
  `now` if the key has that limit (`clamped` says so), `to` no earlier
  than `from`.
  """
  @spec clamp(map(), DateTime.t(), DateTime.t(), DateTime.t()) ::
          {DateTime.t(), DateTime.t(), boolean()}
  def clamp(%{history_days: days}, from, to, now) when is_integer(days) do
    earliest = DateTime.add(now, -days, :day)

    if DateTime.compare(from, earliest) == :lt,
      do: {earliest, Enum.max([to, earliest], DateTime), true},
      else: {from, to, false}
  end

  def clamp(_key, from, to, _now), do: {from, to, false}

  @doc "The resolution asked for, made no finer than the key allows."
  @spec resolution(map(), Resolution.t() | nil) :: Resolution.t() | nil
  def resolution(key, requested),
    do: Resolution.coarsest(requested, Resolution.parse(key.min_res))

  @doc "Whether a key is accepted from an address (`allowed_cidrs` empty: from anywhere)."
  @spec address_allowed?(map(), :inet.ip_address()) :: boolean()
  def address_allowed?(%{allowed_cidrs: []}, _ip), do: true
  def address_allowed?(%{allowed_cidrs: cidrs}, ip), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  @doc "Whether a string is an address or a CIDR (`203.0.113.0/24`, `2001:db8::/32`)."
  @spec cidr_valid?(String.t()) :: boolean()
  def cidr_valid?(cidr), do: match?({:ok, _, _}, parse_cidr(cidr))

  defp in_cidr?(ip, cidr) do
    case parse_cidr(cidr) do
      {:ok, net, bits} when tuple_size(net) == tuple_size(ip) ->
        prefix(ip, bits) == prefix(net, bits)

      _ ->
        false
    end
  end

  defp parse_cidr(cidr) do
    {addr, bits} =
      case String.split(cidr, "/") do
        [addr] -> {addr, nil}
        [addr, bits] -> {addr, Integer.parse(bits)}
        _ -> {nil, nil}
      end

    with addr when is_binary(addr) <- addr,
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         max = if(tuple_size(ip) == 4, do: 32, else: 128),
         bits when is_integer(bits) and bits >= 0 and bits <= max <- bits(bits, max) do
      {:ok, ip, bits}
    else
      _ -> :error
    end
  end

  defp bits(nil, max), do: max
  defp bits({n, ""}, _max), do: n
  defp bits(_, _max), do: nil

  defp prefix(ip, bits) do
    size = if tuple_size(ip) == 4, do: 8, else: 16
    whole = for part <- Tuple.to_list(ip), into: <<>>, do: <<part::size(size)>>
    <<p::bitstring-size(^bits), _::bitstring>> = whole
    p
  end
end
