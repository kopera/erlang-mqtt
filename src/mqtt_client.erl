-module(mqtt_client).
-export([
    connect/1,
    disconnect/1,
    subscribe/2,
    unsubscribe/2,
    publish/3,
    publish/4
]).
-export([
    start_link/2
]).

-behaviour(gen_statem).
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    code_change/4,
    terminate/3
]).

-include("../include/mqtt_packet.hrl").
-define(disconnect_timeout, 5000).


%% Data record
-record(data, {
    owner :: pid(),
    owner_monitor :: reference(),

    transport :: mqtt_transport:transport() | undefined,
    transport_tags :: mqtt_transport:tags() | undefined,
    buffer = <<>> :: binary(),

    next_id = 0 :: mqtt_packet:packet_id(),
    pending_subscribe = #{} :: #{mqtt_packet:packet_id() => {[Topic :: iodata()], gen_statem:from()}},
    pending_unsubscribe = #{} :: #{mqtt_packet:packet_id() => gen_statem:from()},

    keep_alive_ping_timeout = infinity :: timeout(),
    keep_alive_exit_timeout = infinity :: timeout()
}).

-type topic() :: mqtt_packet:topic().
-type qos() :: mqtt_packet:qos().


-spec connect(connect_options()) -> {ok, connection(), SessionPresent :: boolean()} | {error, connect_error()}.
-type connect_options() :: #{
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
-type connect_error() ::
      unacceptable_protocol
    | identifier_rejected
    | server_unavailable
    | bad_username_or_password
    | not_authorized
    | pos_integer()
    | timeout
    | {transport_error, term()}.
-type connection() :: pid().
%% @doc Connect to an mqtt broker.
connect(Opts) ->
    KeepAlive = case maps:get(keep_alive, Opts, 0) of
        N when N > 0 -> N * 1000;
        0 -> infinity
    end,
    mqtt_client_sup:start_connection(self(), #{
        transport => connect_transport(KeepAlive, maps:get(transport, Opts, {tcp, #{}})),
        protocol => maps:get(protocol, Opts, <<"MQTT">>),
        username => maps:get(username, Opts, undefined),
        password => maps:get(password, Opts, undefined),
        client_id => maps:get(client_id, Opts, <<>>),
        clean_session => maps:get(clean_session, Opts, true),
        last_will => case maps:get(last_will, Opts, undefined) of
            undefined ->
                undefined;
            #{topic := Topic, message := Message} = LastWill ->
                #mqtt_last_will{
                    topic = Topic,
                    message = Message,
                    qos = maps:get(qos, LastWill, 0),
                    retain = maps:get(retain, LastWill, false)
                }
        end,
        keep_alive => KeepAlive
    }).

connect_transport(KeepAlive, {Type, Opts}) ->
    Host = maps:get(host, Opts, "localhost"),
    Port = maps:get(port, Opts, case Type of
        tcp -> 1883;
        ssl -> 8883
    end),
    ConnectTimeout = maps:get(connect_timeout, Opts, 15000),
    TransportOpts = [
        {send_timeout, KeepAlive},
        {send_timeout_close, true} |
        maps:to_list(maps:without([host, port, connect_timeout], Opts))
    ],
    {Type, Host, Port, TransportOpts, ConnectTimeout}.


-spec disconnect(connection()) -> ok.
%% @doc Disconnect from an mqtt broker.
disconnect(Connection) ->
    gen_statem:cast(Connection, disconnect).


-spec subscribe(connection(), [{topic(), qos()} | topic()]) -> {ok, [{topic(), qos() | failed}]}.
%% @doc Synchronously subscribe to a set of topics.
subscribe(Connection, Topics) when is_list(Topics) ->
    gen_statem:call(Connection, {subscribe, [case T of
        {Topic, QoS} when (is_binary(Topic) orelse is_list(Topic)) andalso is_integer(QoS) -> {Topic, QoS};
        Topic when is_binary(Topic); is_list(Topic) -> {Topic, 0}
    end || T <- Topics]}).


-spec unsubscribe(connection(), [topic()]) -> ok.
%% @doc Unsubscribe from a set of topics.
unsubscribe(Connection, Topics) when is_list(Topics) ->
    gen_statem:call(Connection, {unsubscribe, Topics}).


-spec publish(connection(), topic(), Message :: iodata()) -> ok.
%% @doc Publish a message to a topic.
publish(Connection, Topic, Message) ->
    publish(Connection, Topic, Message, #{}).


-spec publish(connection(), topic(), Message :: iodata(), publish_options()) -> ok.
-type publish_options() :: #{
    qos => qos(),
    retain => boolean()
}.
%% @doc Publish a message to a topic.
publish(_Connection, _Topic, _Message, #{qos := QoS}) when QoS > 0 ->
    exit(not_implemented);
publish(Connection, Topic, Message, Options) ->
    gen_statem:call(Connection, {publish, Topic, Message, Options}).


%% @private
start_link(Owner, Opts) ->
    case gen_statem:start_link(?MODULE, [Owner], []) of
        {ok, Connection} ->
            case gen_statem:call(Connection, {connect, Opts}) of
                {ok, Present} ->
                    {ok, Connection, Present};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.


%% @private
init([Owner]) ->
    {ok, disconnected, #data{
        owner = Owner,
        owner_monitor = erlang:monitor(process, Owner)
    }}.


%% @private
callback_mode() ->
    handle_event_function.


%% @private
handle_event(info, {DataTag, Source, Data}, _, #data{transport_tags = {DataTag, _, _, Source}} = StateData) ->
    #data{transport = Transport, buffer = Buffer, keep_alive_exit_timeout = KeepAliveExitTimeout} = StateData,
    case decode_packets(<<Buffer/binary, Data/binary>>) of
        {ok, Messages, Rest} ->
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {keep_state, StateData#data{buffer = Rest}, [
                keep_alive_exit_timer(KeepAliveExitTimeout) |
                [{next_event, internal, Message} || Message <- Messages]
            ]};
        {error, Reason} ->
            {stop, {protocol_error, Reason}}
    end;

handle_event(info, {ClosedTag, Source}, _, #data{transport_tags = {_, ClosedTag, _, Source}} = StateData) ->
    {stop, normal, StateData#data{transport = undefined}};

handle_event(info, {ErrorTag, Source, Reason}, _, #data{transport_tags = {_, _, ErrorTag, Source}} = StateData) ->
    {stop, {error, ErrorTag, Reason}, StateData#data{transport = undefined}};

handle_event(EventType, EventContent, disconnected, StateData) ->
    disconnected(EventType, EventContent, StateData);

handle_event(EventType, EventContent, {authenticating, From}, StateData) ->
    authenticating(From, EventType, EventContent, StateData);

handle_event(EventType, EventContent, connected, StateData) ->
    connected(EventType, EventContent, StateData);

handle_event(EventType, EventContent, disconnecting, StateData) ->
    disconnecting(EventType, EventContent, StateData).


%% @private
terminate(_Reason, _State, #data{transport = undefined} = _StateData) ->
    ok;

terminate(_Reason, _State, #data{transport = Transport} = _StateData) ->
    _ = mqtt_transport:close(Transport),
    ok.


%% @private
code_change(_Vsn, State, StateData, _Extra) ->
    {ok, State, StateData}.


%% States

%%%% Disconnected


disconnected({call, From}, {connect, Opts}, #data{} = StateData) ->
    #{
        transport := {TransportType, Host, Port, TransportOpts, ConnectTimeout},
        protocol := Protocol,
        username := Username,
        password := Password,
        client_id := ClientId,
        clean_session := CleanSession,
        last_will := LastWill,
        keep_alive := KeepAlive
    } = Opts,
    {KeepAlivePingTimeout, KeepAliveExitTimeout} = case KeepAlive of
        infinity -> {infinity, infinity};
        _ -> {KeepAlive, trunc(KeepAlive * 1.5)}
    end,

    case mqtt_transport:open(TransportType, Host, Port, TransportOpts, ConnectTimeout) of
        {ok, Transport} ->
            ok = send_packet(Transport, #mqtt_connect{
                protocol_name = Protocol,
                protocol_level = 4,
                last_will = LastWill,
                clean_session = CleanSession,
                keep_alive = case KeepAlive of
                    infinity -> 0;
                    _ -> KeepAlive
                end,
                client_id = ClientId,
                username = Username,
                password = Password
            }),
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {next_state, {authenticating, From}, StateData#data{
                transport = Transport,
                transport_tags = mqtt_transport:get_tags(Transport),

                keep_alive_ping_timeout = KeepAlivePingTimeout,
                keep_alive_exit_timeout = KeepAliveExitTimeout
            }, [
                keep_alive_ping_timer(KeepAlivePingTimeout),
                keep_alive_exit_timer(KeepAliveExitTimeout)
            ]};
        {error, Error} ->
            {stop_and_reply, normal, [
                {reply, From, {error, {transport_error, Error}}}
            ], StateData}
    end;

disconnected(cast, disconnect, _StateData) ->
    {stop, normal};

disconnected(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, StateData).


%%%% Authenticating

authenticating(From, internal, #mqtt_connack{return_code = 0, session_present = Present}, #data{} = StateData) ->
    {next_state, connected, StateData, [
        {reply, From, {ok, Present}}
    ]};

authenticating(From, internal, #mqtt_connack{return_code = Code}, #data{} = StateData) ->
    Error = case Code of
        1 -> unacceptable_protocol;
        2 -> identifier_rejected;
        3 -> server_unavailable;
        4 -> bad_username_or_password;
        5 -> not_authorized;
        _ -> Code
    end,
    {stop_and_reply, normal, [
        {reply, From, {error, Error}}
    ], StateData};

authenticating(_From, cast, disconnect, StateData) ->
    #data{transport = Transport} = StateData,
    ok = send_packet(Transport, #mqtt_disconnect{}),
    {next_state, disconnecting, StateData, [
        {state_timeout, ?disconnect_timeout, undefined}
    ]};

authenticating(_From, {timeout, keep_alive_ping}, _, #data{} = StateData) ->
    #data{transport = Transport, keep_alive_ping_timeout = KeepAlivePingTimeout} = StateData,
    ok = send_packet(Transport, #mqtt_pingreq{}),
    {keep_state_and_data, [
        keep_alive_ping_timer(KeepAlivePingTimeout)
    ]};

authenticating(_From, {timeout, keep_alive_exit}, _, #data{} = _StateData) ->
    {stop, normal};

authenticating(_From, EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, StateData).


%%%% Connected

%%%%%% Subscribe
connected({call, From}, {subscribe, Topics}, StateData) ->
    #data{transport = Transport, next_id = PacketId, pending_subscribe = PendingSubscribe} = StateData,
    ok = send_packet(Transport, #mqtt_subscribe{
        packet_id = PacketId,
        topics = Topics
    }),
    {keep_state, StateData#data{
        next_id = PacketId + 1,
        pending_subscribe = maps:put(PacketId, {[Topic || {Topic, _Qos} <- Topics], From}, PendingSubscribe)
    }};

connected(internal, #mqtt_suback{packet_id = PacketId, acks = Acks}, StateData) ->
    #data{pending_subscribe = PendingSubscribe} = StateData,
    {{Topics, From}, PendingSubscribe1} = maps:take(PacketId, PendingSubscribe),
    {keep_state, StateData#data{pending_subscribe = PendingSubscribe1}, [
        {reply, From, {ok, lists:zip(Topics, Acks)}}
    ]};

%%%%%% Unsubscribe
connected({call, From}, {unsubscribe, Topics}, StateData) ->
    #data{transport = Transport, next_id = PacketId, pending_unsubscribe = PendingUnsubscribe} = StateData,
    ok = send_packet(Transport, #mqtt_unsubscribe{
        packet_id = PacketId,
        topics = Topics
    }),
    {keep_state, StateData#data{
        next_id = PacketId + 1,
        pending_unsubscribe = maps:put(PacketId, From, PendingUnsubscribe)
    }};

connected(internal, #mqtt_unsuback{packet_id = PacketId}, StateData) ->
    #data{pending_unsubscribe = PendingUnsubscribe} = StateData,
    {From, PendingUnsubscribe1} = maps:take(PacketId, PendingUnsubscribe),
    {keep_state, StateData#data{pending_unsubscribe = PendingUnsubscribe1}, [
        {reply, From, ok}
    ]};

%%%%%% Publish
connected({call, From}, {publish, Topic, Message, Options}, StateData) ->
    #data{transport = Transport, next_id = PacketId} = StateData,
    ok = send_packet(Transport, #mqtt_publish{
        packet_id = PacketId,
        retain = maps:get(retain, Options, false),
        topic = Topic,
        message = Message
    }),
    {keep_state, StateData#data{
        next_id = PacketId + 1
    }, [
        {reply, From, ok}
    ]};

connected(internal, #mqtt_publish{topic = Topic, message = Message, qos = 0}, StateData) ->
    #data{owner = Owner} = StateData,
    _ = notify_owner(Owner, {publish, Topic, Message, 0}),
    keep_state_and_data;

connected(internal, #mqtt_publish{}, _StateData) ->
    %% TODO: handle QoS 1 & 2
    exit(not_implemented);

connected(cast, disconnect, StateData) ->
    #data{transport = Transport} = StateData,
    ok = send_packet(Transport, #mqtt_disconnect{}),
    {next_state, disconnecting, StateData, [
        {state_timeout, ?disconnect_timeout, undefined}
    ]};

connected({timeout, keep_alive_ping}, _, #data{} = StateData) ->
    #data{transport = Transport, keep_alive_ping_timeout = KeepAlivePingTimeout} = StateData,
    ok = send_packet(Transport, #mqtt_pingreq{}),
    {keep_state_and_data, [
        keep_alive_ping_timer(KeepAlivePingTimeout)
    ]};

connected({timeout, keep_alive_exit}, _, #data{} = _StateData) ->
    {stop, normal};

connected(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, StateData).


%%%% Disconnecting
disconnecting({call, From}, _, _StateData) ->
    {keep_state_and_data, [
        {reply, From, {error, disconnected}}
    ]};

disconnecting(state_timeout, _EventContent, _StateData) ->
    {stop, normal};

disconnecting(_EventType, _EventContent, _StateData) ->
    keep_state_and_data.


%%%% Any state

handle_event(info, {'DOWN', Monitor, process, Pid, _Info}, #data{owner = Pid, owner_monitor = Monitor} = _StateData) ->
    {stop, normal};

handle_event(_EventType, _EventContent, _StateData) ->
    keep_state_and_data.


%% Helpers

send_packet(Transport, Packet) ->
    mqtt_transport:send(Transport, mqtt_packet:encode(Packet)).

keep_alive_ping_timer(Timeout) ->
    {{timeout, keep_alive_ping}, Timeout, undefined}.

keep_alive_exit_timer(Timeout) ->
    {{timeout, keep_alive_exit}, Timeout, undefined}.

notify_owner(Owner, Message) ->
    Owner ! {?MODULE, self(), Message}.


decode_packets(Data) ->
    case decode_packets(Data, []) of
        {ok, Messages, Rest} ->
            {ok, Messages, binary:copy(Rest)};
        {error, _} = Error ->
            Error
    end.

decode_packets(Data, Acc) ->
    case mqtt_packet:decode(Data) of
        {ok, Message, Rest} ->
            decode_packets(Rest, [Message | Acc]);
        incomplete ->
            {ok, lists:reverse(Acc), Data};
        {error, _} = Error ->
            Error
    end.
