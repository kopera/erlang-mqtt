defmodule MQTT.Mixfile do
  use Mix.Project

  def project do
    [
      app: :mqtt,
      name: "MQTT",
      version: "0.2.3",
      elixir: "~> 1.0",
      package: package(),
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
      {:ex_doc, "~> 0.18.1", only: :dev, runtime: false},
      {:dialyze, "~> 0.2.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 0.8.10", only: [:dev, :test], runtime: false}
    ]
  end
end
