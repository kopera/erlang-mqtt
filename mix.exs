defmodule MQTT.Mixfile do
  use Mix.Project

  def project do
    [
      app: :mqtt,
      name: "MQTT",
      version: "0.3.0",
      elixir: "~> 1.6",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Erlang/Elixir low level MQTT protocol implementation",
      source_url: "https://github.com/kopera/erlang-mqtt",
      deps: deps()
    ]
  end

  def application do
    [
      mod: {:mqtt_app, []},
      registered: [:mqtt_sup, :mqtt_client_sup],
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package() do
    [
      maintainers: ["Ali Sabil"],
      files: [
        "include",
        "lib",
        "LICENSE*",
        "mix.exs",
        "README*",
        "rebar.config",
        "rebar.lock",
        "src"
      ],
      build_tools: ["mix", "rebar3"],
      licenses: ["Apache 2.0"],
      links: %{"Github" => "https://github.com/kopera/erlang-mqtt"}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.18.3", only: :dev, runtime: false},
      {:dialyxir, "~> 0.5.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 0.8.10", only: [:dev, :test], runtime: false},
      {:ranch, "~> 1.5.0", only: [:dev, :test], runtime: false}
    ]
  end
end
