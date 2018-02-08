-module(mqtt_client).
-export([
    connect/1,
    close/1,
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

-record(options, {
    transport :: {tcp, mqtt_transport:host(), mqtt_transport:port_number(), mqtt_transport:tcp_options(), timeout()}
               | {ssl, mqtt_transport:host(), mqtt_transport:port_number(), mqtt_transport:ssl_options(), timeout()},
    protocol :: iodata(),
    username :: undefined | iodata(),
    password :: undefined | iodata(),
    client_id :: iodata(),
    clean_session :: boolean(),
    last_will :: undefined | #mqtt_last_will{},
    keep_alive :: non_neg_integer()
}).

%% Data records
-record(data, {
    owner :: pid(),
    owner_monitor :: reference(),
    options :: #options{},
    transport :: mqtt_transport:transport() | undefined,
    transport_tags :: mqtt_transport:tags() | undefined,
    buffer = <<>> :: binary(),
    keep_alive_timer = undefined :: timer(keep_alive) | undefined,
    keep_alive_exit_timer = undefined :: timer(keep_alive_exit) | undefined,
    next_id = 0 :: mqtt_packet:packet_id(),
    requests :: [{request(), gen_statem:from()}],
    pending_subscriptions = #{} :: #{mqtt_packet:packet_id() => [Topic :: iodata()]}
}).
-type request() ::
      connect
    | {subscribe, mqtt_packet:packet_id(), Topic :: iodata()}
    | {unsubscribe, mqtt_packet:packet_id(), Topic :: iodata()}.


-spec connect(mqtt:start_options()) -> {ok, pid(), integer()} | {error, string()}.
connect(Opts) ->
    mqtt_client_sup:start_connection(self(), Opts).


subscribe(Connection, Topic) ->
    gen_statem:call(Connection, {subscribe, Topic}).


unsubscribe(Connection, Topic) ->
    gen_statem:call(Connection, {unsubscribe, Topic}).


publish(Connection, Topic, Data) ->
    gen_statem:cast(Connection, {publish, Topic, Data}).


publish(Connection, Topic, Data, Options) ->
    gen_statem:cast(Connection, {publish, Topic, Data, Options}).


-spec start_link(pid(), mqtt:start_options()) -> {ok, pid(), integer()} | {error, string()}.
start_link(Owner, Opts) ->
    case gen_statem:start_link(?MODULE, [Owner, start_options(Opts)], []) of
        {ok, Connection} ->
            case gen_statem:call(Connection, connect) of
                {ok, Present} ->
                    {ok, Connection, Present};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.


close(Connection) ->
    try gen_statem:stop(Connection) of
        _ -> ok
    catch
        exit:noproc -> ok
    end.


start_options(Opts) ->
    KeepAlive = maps:get(keep_alive, Opts, 0),
    #options{
        transport = start_options_transport(KeepAlive, maps:get(transport, Opts, {tcp, #{}})),
        protocol = maps:get(protocol, Opts, <<"MQTT">>),
        username = maps:get(username, Opts, undefined),
        password = maps:get(password, Opts, undefined),
        client_id = maps:get(client_id, Opts, <<>>),
        clean_session = maps:get(clean_session, Opts, true),
        last_will = case maps:get(last_will, Opts, undefined) of
            undefined ->
                undefined;
            #{topic := Topic, message := Message} = LastWill ->
                QoS = maps:get(qos, LastWill, 0),
                Retain = maps:get(retain, LastWill, false),
                #mqtt_last_will{topic = Topic, message = Message, qos = QoS, retain = Retain}
        end,
        keep_alive = KeepAlive
    }.


start_options_transport(KeepAlive, {Type, Opts}) ->
    Host = maps:get(host, Opts, "localhost"),
    Port = maps:get(port, Opts, case Type of
        tcp -> 1883;
        ssl -> 8883
    end),
    ConnectTimeout = maps:get(connect_timeout, Opts, 15000),
    TransportOpts = [
        {send_timeout, case KeepAlive of 0 -> infinity; _ -> KeepAlive * 1000 end},
        {send_timeout_close, true} |
        maps:to_list(maps:without([host, port, connect_timeout], Opts))
    ],
    {Type, Host, Port, TransportOpts, ConnectTimeout}.


%% @hidden
init([Owner, #options{} = Options]) ->
    {ok, disconnected, #data{
        owner = Owner,
        owner_monitor = erlang:monitor(process, Owner),
        options = Options,
        requests = []
    }}.


%% @hidden
callback_mode() ->
    handle_event_function.


%% @hidden
handle_event(info, {DataTag, Source, Data}, _, #data{transport_tags = {DataTag, _, _, Source}, keep_alive_timer = KeepAliveTimer, keep_alive_exit_timer = KeepAliveExitTimer} = StateData) ->
    #data{transport = Transport, buffer = Buffer} = StateData,
    case decode_packets(<<Buffer/binary, Data/binary>>) of
        {ok, Messages, Rest} ->
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {keep_state, StateData#data{buffer = Rest, keep_alive_timer = restart_timer(KeepAliveTimer), keep_alive_exit_timer = restart_timer(KeepAliveExitTimer)}, [{next_event, internal, Message} || Message <- Messages]};
        {error, Reason} ->
            {stop, {protocol_error, Reason}}
    end;
handle_event(info, {ClosedTag, Source}, _, #data{transport_tags = {_, ClosedTag, _, Source}} = _StateData) ->
    {stop, normal};
handle_event(info, {ErrorTag, Source, Reason}, _, #data{transport_tags = {_, _, ErrorTag, Source}} = _StateData) ->
    {stop, {error, ErrorTag, Reason}};
handle_event(EventType, EventContent, disconnected, StateData) ->
    disconnected(EventType, EventContent, StateData);
handle_event(EventType, EventContent, authenticating, StateData) ->
    authenticating(EventType, EventContent, StateData);
handle_event(EventType, EventContent, connected, StateData) ->
    connected(EventType, EventContent, StateData).


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


%% @hidden
terminate(_Reason, _State, #data{requests = Requests, transport = Transport, keep_alive_exit_timer = KeepAliveExitTimer, keep_alive_timer = KeepAliveTimer} = _StateData) ->
    _ = stop_timer(KeepAliveTimer),
    _ = stop_timer(KeepAliveExitTimer),
    _ = mqtt_transport:close(Transport),
    gen_statem:reply([{reply, From, {error, disconnected}} || {_, From} <- Requests]),
    ok.


%% @hidden
code_change(_Vsn, State, StateData, _Extra) ->
    {ok, State, StateData}.


%% States

%%%% Disconnected

disconnected({call, From}, connect, #data{options = Options} = StateData) ->
    #options{
        transport = {TransportType, Host, Port, TransportOpts, ConnectTimeout},
        protocol = Protocol,
        username = Username,
        password = Password,
        client_id = ClientId,
        clean_session = CleanSession,
        last_will = LastWill,
        keep_alive = KeepAlive
    } = Options,
    case mqtt_transport:open(TransportType, Host, Port, TransportOpts, ConnectTimeout) of
        {ok, Transport} ->
            Connect = #mqtt_connect{
                protocol_name = Protocol,
                protocol_level = 4,
                last_will = LastWill,
                clean_session = CleanSession,
                keep_alive = KeepAlive,
                client_id = ClientId,
                username = Username,
                password = Password
            },
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {next_state, authenticating, send(Connect, StateData#data{
                requests = [{connect, From}],
                options = Options,
                transport = Transport,
                transport_tags =  mqtt_transport:get_tags(Transport),
                keep_alive_timer = if
                    KeepAlive > 0 ->
                        start_timer(KeepAlive * 1000, keep_alive);
                    KeepAlive =:= 0 ->
                        undefined
                end,
                keep_alive_exit_timer = if
                    KeepAlive > 0 ->
                        start_timer(KeepAlive * 1500, keep_alive_exit);
                    KeepAlive =:= 0 ->
                        undefined
                end
            })};
        {error, Error} ->
            {stop_and_reply, normal, [
                {reply, From, {error, Error}}
            ], StateData}
    end;

disconnected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%%%% Authenticating

authenticating(internal, #mqtt_connack{return_code = 0, session_present = Present}, #data{requests = Requests} = StateData) ->
    [{connect, From}] = Requests,
    {next_state, connected, StateData#data{requests = []}, [{reply, From, {ok, Present}}]};

authenticating(internal, #mqtt_connack{return_code = Code}, #data{requests = Requests} = StateData) ->
    [{connect, From}] = Requests,
    Error = case Code of
        1 -> unacceptable_protocol;
        2 -> identifier_rejected;
        3 -> server_unavailable;
        4 -> bad_username_or_password;
        5 -> not_authorized;
        _ -> {error, Code}
    end,
    {stop_and_reply, normal, [
        {reply, From, {error, Error}}
    ], StateData#data{requests = []}};

authenticating(info, {timeout, Ref, keep_alive}, #data{keep_alive_timer = {timer, Ref, keep_alive, _}} = StateData) ->
    {keep_state, send(#mqtt_pingreq{}, StateData)};


authenticating(info, {timeout, Ref, keep_alive_exit}, #data{requests = Requests, keep_alive_exit_timer = {timer, Ref, keep_alive_exit, _}} = StateData) ->
    [{connect, From}] = Requests,
    {stop_and_reply, normal, [
        {reply, From, {error, keep_alive_exit}}
    ], StateData#data{requests = []}};

authenticating(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%%%% Connected

connected(internal, #mqtt_publish{topic = Topic, message = Message, qos = 0}, StateData) ->
    #data{owner = Owner} = StateData,
    _ = notify_owner(Owner, {publish, Topic, Message}),
    keep_state_and_data;

connected(internal, #mqtt_publish{}, _StateData) ->
    %% TODO: handle QoS 1 & 2
    keep_state_and_data;

connected(internal, #mqtt_suback{packet_id = PacketId, acks = Acks}, StateData) ->
    #data{pending_subscriptions = Pending, requests = Requests} = StateData,
    case maps:take(PacketId, Pending) of
        {[Topic], PendingSubscriptions} ->
            {From, PendingRequests} = take_request({subscribe, PacketId, Topic}, Requests),
            {keep_state, StateData#data{requests = PendingRequests, pending_subscriptions = PendingSubscriptions}, [
                {reply, From, {ok, Acks}}
            ]};
        error ->
            keep_state_and_data
    end;

connected(internal, #mqtt_unsuback{packet_id = PacketId}, StateData) ->
    #data{pending_subscriptions = Pending, requests = Requests} = StateData,
    case maps:take(PacketId, Pending) of
        {[Topic], PendingSubscriptions} ->
            {From, PendingRequests} = take_request({unsubscribe, PacketId, Topic}, Requests),
            {keep_state, StateData#data{requests = PendingRequests, pending_subscriptions = PendingSubscriptions}, [
                {reply, From, ok}
            ]};
        error ->
            keep_state_and_data
    end;

connected({call, From}, {subscribe, Topic}, StateData) ->
    #data{next_id = Id, pending_subscriptions = Pending, requests = Requests} = StateData,
    Topics = [{Topic, 0}],
    SubscribeMessage = #mqtt_subscribe{
        packet_id = Id,
        topics = Topics
    },
    {keep_state, send(SubscribeMessage, StateData#data{
        next_id = Id + 1,
        pending_subscriptions = maps:put(Id, [SubTopic || {SubTopic, _Qos} <- Topics], Pending),
        requests = put_request({subscribe, Id, Topic}, From, Requests)
    })};

connected({call, From}, {unsubscribe, Topic}, StateData) ->
    #data{next_id = Id, pending_subscriptions = Pending, requests = Requests} = StateData,
    Topics = [Topic],
    UnSubscribeMessage = #mqtt_unsubscribe{
        packet_id = Id,
        topics = Topics
    },
    {keep_state, send(UnSubscribeMessage, StateData#data{
        next_id = Id + 1,
        pending_subscriptions = maps:put(Id, [UnSubTopic || UnSubTopic <- Topics], Pending),
        requests = put_request({unsubscribe, Id, Topic}, From, Requests)
    })};

connected(cast, {publish, Topic, Message}, StateData) ->
    {keep_state, send(#mqtt_publish{
        retain = false,
        topic = Topic,
        message = Message
    }, StateData)};

connected(cast, {publish, _Topic, _Data, Options}, _StateData) ->
    _QoS = maps:get(qos, Options, 0),
    _Retain = maps:get(retain, Options, false),
    keep_state_and_data;

connected(info, {timeout, Ref, keep_alive}, #data{keep_alive_timer = {timer, Ref, keep_alive, _}} = StateData) ->
    {keep_state, send(#mqtt_pingreq{}, StateData)};

connected(info, {timeout, Ref, keep_alive_exit}, #data{keep_alive_exit_timer = {timer, Ref, keep_alive_exit, _}} = _StateData) ->
    {stop, keep_alive_exit};

connected(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, StateData).


%% Extra handlers

handle_event(internal, #mqtt_pingresp{}, _Data) ->
    keep_state_and_data;

handle_event(_, _, _Data) ->
    keep_state_and_data.


%% Helpers

send(Packet, Data) ->
    #data{transport = Transport} = Data,
    case mqtt_transport:send(Transport, mqtt_packet:encode(Packet)) of
        ok ->
            Data;
        Error ->
            {stop, {error, Error}}
    end.


put_request(Request, From, Requests) ->
    Requests ++ [{Request, From}].


take_request(Request, Requests) ->
    {value, {Request, From}, PendingRequests} = lists:keytake(Request, 1, Requests),
    {From, PendingRequests}.


notify_owner(Owner, Message) ->
    Owner ! {?MODULE, self(), Message}.


-spec start_timer(non_neg_integer(), Tag) -> timer(Tag) when Tag :: term().
-type timer(Tag) :: {timer, reference(), Tag, MilliSecs :: non_neg_integer()}.
start_timer(MilliSecs, Tag) ->
    Ref = erlang:start_timer(MilliSecs, self(), Tag),
    {timer, Ref, Tag, MilliSecs}.

-spec stop_timer(timer(term()) | undefined) -> undefined.
stop_timer(undefined) ->
    undefined;
stop_timer({timer, Ref, _, _}) ->
    _ = erlang:cancel_timer(Ref),
    undefined.

-spec restart_timer(timer(Tag) | undefined) -> timer(Tag) | undefined when Tag :: term().
restart_timer(undefined) ->
    undefined;
restart_timer({timer, Ref, Tag, MilliSecs}) ->
    _ = erlang:cancel_timer(Ref),
    start_timer(MilliSecs, Tag).
