defmodule Sim.Recorder.AnalysisTest do
  use ExUnit.Case, async: true

  alias Sim.Recorder.{RetryAnalysis, ViewerRefresh, WebhookPolicy}

  describe "ViewerRefresh.summarize/1" do
    test "counts changes and the time between them, ignoring missing readings" do
      samples =
        [{0, 100}, {15, 100}, {30, 120}, {45, 120}, {60, nil}, {75, 120}, {90, 130}, {105, 131}]
        |> Enum.map(fn {s, v} -> %{at_ms: s * 1000, viewers: v} end)
        |> Enum.shuffle()

      summary = ViewerRefresh.summarize(samples)

      assert summary["samples"] == 7
      assert summary["changes"] == 3
      assert summary["distinct_values"] == 4
      # Changes seen at 30s, 90s and 105s.
      assert summary["seconds_between_changes"] == %{
               "min" => 15.0,
               "median" => 37.5,
               "max" => 60.0,
               "count" => 2
             }
    end

    test "a flat series has no changes" do
      samples = for s <- 0..3, do: %{at_ms: s * 15_000, viewers: 50}

      assert %{"changes" => 0, "seconds_between_changes" => nil} =
               ViewerRefresh.summarize(samples)
    end
  end

  describe "RetryAnalysis.summarize/1" do
    test "groups attempts per message and collects delays per retry number" do
      deliveries = [
        %{message_id: "a", at_ms: 0, status: 500},
        %{message_id: "a", at_ms: 10_000, status: 500},
        %{message_id: "a", at_ms: 70_000, status: 200},
        %{message_id: "b", at_ms: 5_000, status: 200},
        %{message_id: "c", at_ms: 8_000, status: 500}
      ]

      summary = RetryAnalysis.summarize(Enum.shuffle(deliveries))

      assert summary["messages"] == 3
      assert summary["deliveries"] == 5
      assert summary["messages_retried"] == 1
      assert summary["messages_never_accepted"] == 1
      assert summary["max_attempts"] == 3
      assert summary["delay_by_retry"] == %{"1" => [10.0], "2" => [60.0]}
      assert summary["per_message"]["a"]["statuses"] == [500, 500, 200]
      assert summary["per_message"]["a"]["span_s"] == 70.0
    end

    test "no deliveries is an empty summary, not a crash" do
      assert %{"messages" => 0, "max_attempts" => 0} = RetryAnalysis.summarize([])
    end
  end

  describe "WebhookPolicy" do
    test "status/3 fails during the fail window and for the first attempts" do
      state = %{fail_until: 1_000, fail_first: 2}
      assert WebhookPolicy.status(state, 5, 999) == 500
      assert WebhookPolicy.status(state, 2, 5_000) == 500
      assert WebhookPolicy.status(state, 3, 5_000) == 200
    end

    test "decide/2 counts attempts per message and logs every delivery" do
      {:ok, policy} = WebhookPolicy.start_link(fail_first: 1)

      assert WebhookPolicy.decide(policy, "a") == 500
      assert WebhookPolicy.decide(policy, "b") == 500
      assert WebhookPolicy.decide(policy, "a") == 200

      assert policy |> WebhookPolicy.deliveries() |> Enum.map(&{&1.message_id, &1.status}) ==
               [{"a", 500}, {"b", 500}, {"a", 200}]
    end

    test "with no options everything is accepted" do
      {:ok, policy} = WebhookPolicy.start_link([])
      assert WebhookPolicy.decide(policy, "a") == 200
    end
  end
end
