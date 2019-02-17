defmodule Cables.MixProject do
  use Mix.Project

  def project do
    [
      app: :cables,
      version: "0.2.1",
      elixir: "~> 1.7",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: description(),
      package: package(),
      name: "Cables",
      source_url: "https://github.com/hansonkd/cables"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Cables.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gun, "~> 1.3"},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      source_url: "https://github.com/hansonkd/cables",
      extras: ["README.md"]
    ]
  end

  defp description() do
    """
    An experimental asynchronous multiplexed HTTP/2 Client for Elixir. Streams are consumed by modules implementing `Cables.Handler` which build a state by looping over chunks of data returned by the request.
    """
  end

  defp package() do
    [
      # These are the default files included in the package
      maintainers: ["Kyle Hanson"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/hansonkd/cables"}
    ]
  end
end
