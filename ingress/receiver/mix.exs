defmodule Receiver.MixProject do
  use Mix.Project

  def project do
    [
      app: :receiver,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {Receiver.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:jason, "~> 1.4"},
      {:amqp, "~> 4.2"},
      {:exqlite, "~> 0.41.0"},
      {:req, "~> 0.7.4"},
      # Validates our envelopes against contracts/envelope.schema.json.
      {:jsv, "~> 0.24.0", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
