defmodule Sim.Fixtures.Recording do
  @moduledoc """
  Anonymizes one raw recording (as written by the recorder) into its fixture
  form, using `Sim.Fixtures.Anonymizer` for payloads. Pure.

  Beyond payloads: request headers are dropped (they carry our User-Agent and
  token), response headers are reduced to an allow-list, slugs in URLs and
  query params are pseudonymized, non-JSON bodies are replaced by a note, and
  webhook signatures are replaced (an anonymized body no longer matches the
  original signature; the simulator signs with its own key).
  """

  alias Sim.Fixtures.Anonymizer

  @response_headers ~w(content-type date cache-control age retry-after)
  @webhook_headers ~w(content-type kick-event-message-id kick-event-subscription-id
                      kick-event-message-timestamp kick-event-type kick-event-version)

  @spec anonymize(map(), Anonymizer.t()) :: {map(), Anonymizer.t()}
  def anonymize(%{"kind" => "http"} = rec, state) do
    {request, state} = request(rec["request"], state)
    {body, state} = body(get_in(rec, ["response", "body"]), state)

    response = %{
      "status" => get_in(rec, ["response", "status"]),
      "headers" =>
        rec |> get_in(["response", "headers"]) |> List.wrap() |> keep_headers(&response_header?/1),
      "body" => body
    }

    {%{rec | "request" => request, "response" => response}, state}
  end

  def anonymize(%{"kind" => "webhook"} = rec, state) do
    {body, state} = body(get_in(rec, ["request", "body"]), state)

    headers =
      rec
      |> get_in(["request", "headers"])
      |> keep_headers(&(&1 in @webhook_headers))
      |> Kernel.++([["kick-event-signature", "[original signature removed: body anonymized]"]])

    rec =
      rec
      |> Map.put("request", %{rec["request"] | "headers" => headers, "body" => body})
      |> Map.put("original_signature_valid", rec["signature_valid"])
      |> Map.delete("signature_valid")
      |> Map.put("anonymized", true)

    {rec, state}
  end

  def anonymize(rec, state), do: {rec, state}

  @doc "Anonymizes one line of a Pusher recording."
  @spec pusher_line(map(), Anonymizer.t()) :: {map(), Anonymizer.t()}
  def pusher_line(%{"frame" => frame} = line, state) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, %{} = decoded} ->
        {decoded, state} = pusher_frame(decoded, state)
        {%{line | "frame" => Jason.encode!(decoded)}, state}

      _ ->
        {%{line | "frame" => "[non-JSON frame, #{byte_size(frame)} bytes]"}, state}
    end
  end

  def pusher_line(%{"frame" => %{} = meta} = line, state) do
    {channels, state} =
      Enum.map_reduce(List.wrap(meta["channels"]), state, &Anonymizer.channel_name/2)

    meta = if Map.has_key?(meta, "channels"), do: %{meta | "channels" => channels}, else: meta
    {%{line | "frame" => meta}, state}
  end

  def pusher_line(line, state), do: {line, state}

  defp pusher_frame(frame, state) do
    {channel, state} =
      case frame["channel"] do
        name when is_binary(name) -> Anonymizer.channel_name(name, state)
        other -> {other, state}
      end

    {data, state} = pusher_data(frame["data"], state)

    frame = frame |> put_if_present("channel", channel) |> put_if_present("data", data)
    {frame, state}
  end

  # Pusher's data is often a JSON document encoded as a string.
  defp pusher_data(data, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        {decoded, state} = Anonymizer.anonymize(decoded, ["data"], state)
        {Jason.encode!(decoded), state}

      _ ->
        {data, state}
    end
  end

  defp pusher_data(data, state) when is_map(data), do: Anonymizer.anonymize(data, ["data"], state)
  defp pusher_data(data, state), do: {data, state}

  defp request(req, state) do
    {url, state} = url(req["url"], state)
    {params, state} = params(req["params"] || %{}, state)

    {json, state} =
      if req["json"], do: Anonymizer.anonymize(req["json"], [], state), else: {nil, state}

    {%{"method" => req["method"], "url" => url, "params" => params, "json" => json}, state}
  end

  # The personal parts of our URLs: whatever follows /channels/, a slug or a
  # numeric id.
  defp url(nil, state), do: {nil, state}

  defp url(url, state) do
    uri = URI.parse(url)
    segments = String.split(uri.path || "", "/")

    {segments, state} =
      segments
      |> Enum.with_index()
      |> Enum.map_reduce(state, fn {seg, i}, state ->
        after_channels? = i > 0 and Enum.at(segments, i - 1) == "channels" and seg != ""

        cond do
          after_channels? and seg =~ ~r/^\d+$/ -> Anonymizer.id(seg, state)
          after_channels? -> Anonymizer.name(URI.decode(seg), state)
          true -> {seg, state}
        end
      end)

    {URI.to_string(%{uri | path: Enum.join(segments, "/")}), state}
  end

  defp params(params, state) do
    Enum.reduce(params, {%{}, state}, fn {key, value}, {acc, state} ->
      {value, state} =
        cond do
          key == "slug" and is_binary(value) ->
            Anonymizer.name(value, state)

          key in ["broadcaster_user_id", "ids[]", "id"] and not is_nil(value) ->
            Anonymizer.id(value, state)

          true ->
            {value, state}
        end

      {Map.put(acc, key, value), state}
    end)
  end

  defp body(nil, state), do: {nil, state}

  defp body(body, state) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {decoded, state} = Anonymizer.anonymize(decoded, [], state)
        {Jason.encode!(decoded), state}

      {:error, _} ->
        {"[non-JSON body, #{byte_size(body)} bytes]", state}
    end
  end

  defp keep_headers(headers, keep?) do
    Enum.filter(headers, fn [name, _] -> keep?.(String.downcase(name)) end)
  end

  defp response_header?(name) do
    name in @response_headers or String.contains?(name, "ratelimit") or
      String.contains?(name, "rate-limit")
  end

  defp put_if_present(map, key, value),
    do: if(Map.has_key?(map, key), do: Map.put(map, key, value), else: map)
end
