-module(mqtt).
-export([
    connect/1,
    disconnect/1,
    subscribe/2,
    unsubscribe/2,
    publish/3,
    publish/4
]).
-export_type([
    start_options/0
]).

-type start_options() :: #{
    transport => {tcp, map()} | {ssl, map()},
    keep_alive => non_neg_integer(),
    protocol => iodata(),
    username => iodata(),
    password => iodata(),
    client_id => iodata(),
    clean_session => boolean(),
    last_will => #{
        topic := iodata(),
        message := iodata(),
        qos => mqtt_packet:qos(),
        retain => boolean()
    }
}.


-spec connect(start_options()) -> {ok, connection(), Status :: integer() }| {error, string()}.
-type connection() :: pid().
%% @doc Connect to a mqtt client.
connect(Opts) ->
    mqtt_client:connect(Opts).


-spec disconnect(connection()) -> ok.
%% @doc Disconnect from a mqtt_client.
disconnect(Connection) ->
    mqtt_client:close(Connection).


-spec subscribe(connection(), Topic :: iodata()) -> {ok, atom()} | {error, term()}.
%% @doc Synchronously subscribe a topic.
subscribe(Connection, Topic) ->
    mqtt_client:subscribe(Connection, Topic).


-spec unsubscribe(connection(), Topic :: iodata()) -> ok | {error, term()}.
%% @doc unsubscribe a topic.
unsubscribe(Connection, Topic) ->
    mqtt_client:unsubscribe(Connection, Topic).

-spec publish(connection(), Topic :: iodata(), iodata()) -> ok.
%% @doc publish data on a topic.
publish(Connection, Topic, Data) ->
    mqtt_client:publish(Connection, Topic, Data).

-spec publish(connection(), Topic :: iodata(), iodata(), #{qos => mqtt_packet:qos(), retain => boolean()}) -> ok.
%% @doc publish data on a topic.
publish(Connection, Topic, Data, Opts) ->
    mqtt_client:publish(Connection, Topic, Data, Opts).
