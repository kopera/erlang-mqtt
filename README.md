# erlang-mqtt [![Build Status](https://travis-ci.org/kopera/erlang-mqtt.svg?branch=master)](https://travis-ci.org/kopera/erlang-mqtt)

MQTT Protocol library for Erlang/Elixir. This library provides the low level building blocks for MQTT.

## Protocol

`mqtt_packet` exposes an `encode` function and a `decode` function to convert binaries to MQTT packets as defined in
`mqtt/include/mqtt_packet.hrl`

## Client

`mqtt_client` provides a simple client for MQTT. Currently this client only supports QoS 0 messages.

### Example Erlang client usage

```erlang
mqtt_client_sup:start_link(),

{ok, Connection, false} = mqtt_client:connect(#{
    transport => {tcp, #{host => "localhost"}}
}),

Topic = <<"/test">>,
{ok, [{Topic, 0}]} = mqtt_client:subscribe(Connection, [{topic, 0}]),

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

## TODO

### Add support for QoS 1 and 2

We need to add support for QoS 1 and 2 messages, this would require implementing a storage module in order to persist
messages until they get acknowledged by the broker.
