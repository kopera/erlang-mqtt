defmodule MQTT.Mixfile do
  use Mix.Project

  def project do
    [app: :mqtt,
     name: "MQTT",
     version: "0.2.1",
     elixir: "~> 1.0",
     package: package(),
     description: "Erlang/Elixir low level MQTT protocol implementation",
     deps: deps()]
  end

  defp package() do
    [maintainers: ["Ali Sabil"],
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
     links: %{"Github" => "https://github.com/kopera/erlang-mqtt"}]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.15.0", only: :dev},
    ]
  end
end
