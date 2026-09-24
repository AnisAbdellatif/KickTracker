defmodule Sim.MixProject do
  use Mix.Project

  def project do
    [
      app: :sim,
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
      mod: {Sim.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:mint_web_socket, "~> 1.0"},
      {:websock_adapter, "~> 0.6", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
