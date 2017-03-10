# erlang-mqtt

MQTT Protocol library for Erlang/Elixir. This library provides the low level building blocks for MQTT.

## Protocol

`mqtt_packet` exposes an `encode` function and a `decode` function to convert binaries to MQTT packets as defined in
`mqtt/include/mqtt_packet.hrl`

## Client

`mqtt_client` provides a client behaviour for MQTT. A client would implement the `mqtt_client` behaviour, and would then
be able to connect to an MQTT broker/server. Currently this client only supports publishing QoS 0 messages.

### Example client behaviour

```erlang
-module(my_mqtt_client).
-export([
    report/1
]).

-export([
    start_link/0
]).

-behaviour(mqtt_client).
-export([
    init/1,
    handle_connect/2,
    handle_connect_error/2,
    handle_disconnect/2,
    handle_publish/3,
    handle_subscribe_result/3,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).


-record(state, {}).

-spec start_link() -> {ok, pid()}.
start_link() ->
    mqtt_client:start_link({local, ?MODULE}, ?MODULE, [], #{
        transport => {tcp, #{host => "localhost", port => 1883}},
        protocol => "MYMQTT/1.0"
    }).

-spec report(iodata()) -> ok.
report(Data) ->
    mqtt_client:cast(?MODULE, {report, Data}).


%% @hidden
init([]) ->
    {ok, #state{}}.

%% @hidden
%% Called whenever we get connected
handle_connect(_SessionPresent, State) ->
    {ok, State}.

%% @hidden
%% Called whenever we fail to connect, either because the connect request was rejected, or because we failed to
%% establish a connection at the transport (TCP) level.
handle_connect_error(Reason, State) ->
    error_logger:error_msg("Unable to connect to MQTT broker: ~p~n", [Reason]),
    {reconnect, {backoff, 5000, 15000}, State}.

%% @hidden
%% Called whenever we get disconnected.
handle_disconnect(Reason, State) ->
    error_logger:warning_msg("Disconnected from MQTT broker: ~p~n", [Reason]),
    {reconnect, {backoff, 200, 15000}, State}.

%% @hidden
%% Called whenever a message is received on a `topic`
handle_publish(_Topic, _Message, State) ->
    {ok, State}.

%% @hidden
%% Called whenever a `suback` is received, the Result is either `failed` or the granted QoS level.
handle_subscribe_result(_Topic, _Result, State) ->
    {ok, State}.

%% @hidden
handle_call(Request, From, State) ->
    {ok, State, {reply, From, {error, {unhandled_request, Request}}}}.

%% @hidden
handle_cast({report, Data}, State) ->
    {ok, State, {publish, "/my/data/topic", Data}};
handle_cast(_Request, State) ->
    {ok, State}.

%% @hidden
handle_info(_Info, State) ->
    {ok, State}.

%% @hidden
terminate(_Reason, _State) ->
    ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
```

## TODO

### Add support for QoS 1 and 2

We need to add support for QoS 1 and 2 messages, this would require implementing a storage module in order to persist
messages until they get acknowledged by the broker.
