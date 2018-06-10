defmodule TestServer do
  use Application

  def start(_type, _args) do
    opts = [
      strategy: :one_for_one,
      name: TestServer.Supervisor
    ]

    children = [
      ranch_sup(),
      ranch_listner_sup()
    ]

    Supervisor.start_link(children, opts)
  end

  def ranch_sup() do
    %{
      id: :ranch_sup,
      start: {:ranch_sup, :start_link, []}
    }
  end

  def ranch_listner_sup() do
    ref = :test_server
    num_acceptors = 10
    ranch_module = :ranch_tcp
    transport_opts = [{:port, 1883}]
    proto_opts = []

    %{
      id: {:ranch_listener_sup, ref},
      start:
        {:ranch_listener_sup, :start_link,
         [
           ref,
           num_acceptors,
           ranch_module,
           transport_opts,
           TestServer.Connection,
           proto_opts
         ]},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor,
      modules: [:ranch_listener_sup]
    }
  end
end
