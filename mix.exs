defmodule MQTT.Mixfile do
  use Mix.Project

  def project do
    [
      app: :mqtt,
      name: "MQTT",
      version: "0.3.2",
      elixir: "~> 1.6",
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
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.1.5", only: [:dev, :test], runtime: false}
    ]
  end
end
