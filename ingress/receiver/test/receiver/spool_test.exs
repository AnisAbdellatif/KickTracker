defmodule Receiver.SpoolTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Receiver.Spool

  defp start(dir), do: start_supervised!({Spool, path: Path.join(dir, "spool.sqlite3")})

  test "stores, lists oldest first, and deletes", %{tmp_dir: dir} do
    start(dir)
    :ok = Spool.put("m1", "channel.followed", "one")
    :ok = Spool.put("m2", "kicks.gifted", "two")

    assert Spool.count() == 2

    assert [{id1, "m1", "channel.followed", "one"}, {_, "m2", "kicks.gifted", "two"}] =
             Spool.take(10)

    :ok = Spool.delete(id1)
    assert [{_, "m2", _, _}] = Spool.take(10)
  end

  test "the same message id is kept once, however often it's retried", %{tmp_dir: dir} do
    start(dir)
    for _ <- 1..3, do: :ok = Spool.put("m1", "channel.followed", "one")
    assert Spool.count() == 1
  end

  test "payloads come back byte for byte", %{tmp_dir: dir} do
    start(dir)
    payload = <<0, 255, 1>> <> ~s({"x": "é"})
    :ok = Spool.put("m1", "k", payload)
    assert [{_, _, _, ^payload}] = Spool.take(1)
  end

  test "what's spooled survives the receiver stopping and starting again", %{tmp_dir: dir} do
    start(dir)
    :ok = Spool.put("m1", "k", "one")
    stop_supervised!(Spool)

    start(dir)
    assert [{_, "m1", "k", "one"}] = Spool.take(10)
  end

  test "concurrent writes are all kept", %{tmp_dir: dir} do
    start(dir)

    1..200
    |> Task.async_stream(&Spool.put("m#{&1}", "k", "p#{&1}"), max_concurrency: 50)
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    assert Spool.count() == 200
  end

  test "writing to a spool that isn't running is an error, not a crash" do
    assert {:error, {:spool_unavailable, _}} = Spool.put("m1", "k", "one")
  end
end
