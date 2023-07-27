defmodule Doku.MixProject do
  use Mix.Project

  def project do
    [
      app: :doku,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Doku.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:finch, "~> 0.16.0"},
      {:floki, "~> 0.34.3"},
      {:jason, "~> 1.4"}
    ]
  end
end
