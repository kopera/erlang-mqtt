# erlang-mqtt [![Build Status](https://travis-ci.org/kopera/erlang-mqtt.svg?branch=master)](https://travis-ci.org/kopera/erlang-mqtt)

MQTT Protocol library for Erlang/Elixir. This library provides the low level building blocks for MQTT.

## Protocol

`mqtt_packet` exposes an `encode` function and a `decode` function to convert binaries to MQTT packets as defined in
`mqtt/include/mqtt_packet.hrl`

## Client

`mqtt_client` provides a simple client for MQTT. Currently this client only supports QoS 0 messages.

### Example Erlang client usage

```erlang
{:ok, Connection, false} = mqtt_client:connect(#{
    transport => {tcp, #{host => "localhost"}}
}),

Topic = <<"/test">>,
{:ok, [{Topic, 0}]} = mqtt_client:subscribe(Connection, [{topic, 0}]),

ok = mqtt_client:publish(Connection, Topic, <<"Hello">>),
receive
    {mqtt_client, Connection, {publish, Topic, Message, _}} ->
        io:format("Got ~s published on ~s~n", [Message, Topic]
end.
```

### Example Elixir client usage

```elixir
{:ok, connection, false} = MQTT.Client.connect(%{
    transport: {:tcp, %{host: "localhost"}}
})

topic = "/test"
{:ok, [{^topic, 0}]} = MQTT.Client.subscribe(connection, [{topic, 0}])

:ok = MQTT.Client.publish(connection, topic, "Hello")
receive do
    {:mqtt_client, ^connection, {:publish, ^topic, message, _}} ->
        IO.puts "Got #{message} published on #{topic}"
end
```

## Server

`mqtt_server` provides a server behaviour for MQTT. A server would implement the `mqtt_server` behaviour, and would then
be able to accept MQTT connections from clients. Currently this server only supports QoS 0 messages.

### Example Elixir server usage

Application:

```elixir
defmodule MyMQTTServer.Application do
  use Application

  def start(_type, _args) do
    opts = [
      strategy: :one_for_one,
      name: MyMQTTServer.Supervisor
    ]

    children = [
      :ranch.child_spec(
        :my_mqtt_server,
        :ranch_tcp,
        [{:port, 1883}],
        MyMQTTServer.Connection,
        []
      )
    ]

    Supervisor.start_link(children, opts)
  end
end
```

Connection:

```elixir
defmodule MyMQTTServer.Connection do
  use MQTT.Server

  def start_link(ref, ranch_socket, ranch_transport, options) do
    :proc_lib.start_link(__MODULE__, :init, [ref, ranch_socket, ranch_transport, options])
  end

  def stop(pid) do
    MQTT.Server.stop(pid, :normal, 500)
  end

  def init(ref, ranch_socket, ranch_transport, _options) do
    :ok = :proc_lib.init_ack({:ok, self()})
    :ok = :ranch.accept_ack(ref)
    transport = MQTT.Transport.new(ranch_transport.name(), ranch_socket)
    MQTT.Server.enter_loop(__MODULE__, [], transport)
  end

  def init(_args, %{protocol: <<"MQTT">>}) do
    {:ok, :my_state}
  end

  def init(_args, _) do
    {:stop, :unacceptable_protocol}
  end

  def handle_publish(_topic, _msg, _opts, state) do
    {:ok, state}
  end

  def handle_subscribe(_topic, _qos, state) do
    {:ok, :failed, state}
  end

  def handle_unsubscribe(_topic, state) do
    {:ok, state}
  end

  def handle_call(msg, from, state) do
    {:ok, state, {:reply, from, {:error, {:bad_call, msg}}}}
  end

  def handle_info(msg, state) do
    {:ok, state}
  end

  def handle_cast(msg, state) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  def code_change(_old, state, _extra) do
    {:ok, state}
  end
end
```

## TODO

### Add support for QoS 1 and 2

We need to add support for QoS 1 and 2 messages, this would require implementing a storage module in order to persist
messages until they get acknowledged by the broker.
