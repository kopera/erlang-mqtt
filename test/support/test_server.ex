defmodule TestServer do
  use Application

  def start(_type, _args) do
    opts = [
      strategy: :one_for_one,
      name: TestServer.Supervisor
    ]

    children = [
      ranch_listner()
    ]

    Supervisor.start_link(children, opts)
  end

  def ranch_listner() do
    :ranch.child_spec(
      :test_server,
      :ranch_tcp,
      [{:port, 1883}],
      TestServer.Connection,
      []
    )
  end
end
