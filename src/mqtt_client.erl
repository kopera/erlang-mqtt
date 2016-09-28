-module(mqtt_client).
-export([
    start_link/3,
    start_link/4,
    stop/1,
    stop/3,
    cast/2,
    call/2,
    call/3
]).

-behaviour(gen_statem).
-export([
    init/1,
    callback_mode/0,
    handle_event/4,
    code_change/4,
    terminate/3
]).

-callback init(Args :: any()) ->
      {ok, State :: any()}
    | {stop, Reason :: term()}
    | ignore.
-callback handle_connect(SessionPresent :: boolean(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_connect_error(Reason :: term(), State :: any()) ->
      {reconnect, {backoff, Min :: non_neg_integer(), Max :: pos_integer()}, State :: any()}
    | {stop, Reason :: term()}.
-callback handle_disconnect(Reason :: term(), State :: any()) ->
      {reconnect, {backoff, Min :: non_neg_integer(), Max :: pos_integer()}, State :: any()}
    | {stop, Reason :: term()}.
-callback handle_publish(Topic :: binary(), Message :: binary(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_subscribe_result(Topic :: binary(), mqtt_packet:qos() | failed, State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_call(Call :: any(), From :: gen_statem:from(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_cast(Cast :: any(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_info(Info :: any(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback terminate(normal | shutdown | {shutdown, term()} | term(), State :: any()) ->
    any().
-callback code_change(OldVsn :: term() | {down, term()}, OldState :: any(), Extra :: term()) ->
      {ok, NewState :: any()}
    | term().

-type action() ::
      {publish, Topic :: iodata(), Message :: iodata()}
    | {publish, Topic :: iodata(), Message :: iodata(), #{qos => mqtt_packet:qos(), retain => boolean()}}
    | {subscribe, Topic :: iodata()}
    | {subscribe, Topic :: iodata(), #{qos => mqtt_packet:qos()}}
    | {reply, gen_statem:from(), term()}.

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
-record(disconnected, {
    options :: #options{},
    callback :: module(),
    callback_state :: any(),
    failures = 0 :: non_neg_integer(),
    reconnect_timer = undefined :: reference() | undefined
}).

-record(connected, {
    options :: #options{},
    callback :: module(),
    callback_state :: any(),
    transport :: mqtt_transport:transport(),
    transport_tags :: mqtt_transport:tags(),
    buffer = <<>> :: binary(),
    keep_alive_timer = undefined :: {KeepAlive :: pos_integer(), reference()} | undefined,
    next_id = 0 :: mqtt_packet:packet_id(),
    pending_subscriptions = #{} :: #{mqtt_packet:packet_id() => [Topic :: iodata()]}
}).

-spec start_link(module(), any(), start_options()) -> {ok, pid()}.
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
start_link(Module, Args, Opts) ->
    gen_statem:start_link(?MODULE, [Module, Args, start_options(Opts)], []).

-spec start_link(gen:emgr_name(), module(), any(), start_options()) -> {ok, pid()}.
start_link(Name, Module, Args, Opts) ->
    gen_statem:start_link(Name, ?MODULE, [Module, Args, start_options(Opts)], []).

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


-spec stop(Ref :: client_ref()) -> ok.
-type client_ref() :: pid() | atom() | {atom(), node()} | {global, term()} | {via, module(), term()}.
stop(Ref) ->
    gen_statem:stop(Ref).

-spec stop(Ref :: client_ref(), Reason :: term(), Timeout :: timeout()) -> ok.
stop(Ref, Reason, Timeout) ->
    gen_statem:stop(Ref, Reason, Timeout).

-spec cast(Ref :: client_ref(), Request :: term()) -> Reply :: term().
cast(Ref, Request) ->
    gen_statem:cast(Ref, Request).

-spec call(Ref :: client_ref(), Request :: term()) -> Reply :: term().
call(Ref, Request) ->
    gen_statem:call(Ref, Request).

-spec call(Ref :: client_ref(), Request :: term(), Timeout :: timeout()) -> Reply :: term().
call(Ref, Request, Timeout) ->
    gen_statem:call(Ref, Request, Timeout).

%% @hidden
init([Callback, Args, #options{} = Options]) ->
    case Callback:init(Args) of
        {ok, State} ->
            {ok, disconnected, #disconnected{
                options = Options,
                callback = Callback,
                callback_state = State
            }, {next_event, internal, connect}};
        Other ->
            Other
    end.

%% @hidden
callback_mode() ->
    handle_event_function.

%% @hidden
handle_event(info, {DataTag, Source, Data}, _, #connected{transport_tags = {DataTag, _, _, Source}} = Connected) ->
    #connected{transport = Transport, buffer = Buffer} = Connected,
    case decode_packets(<<Buffer/binary, Data/binary>>) of
        {ok, Messages, Rest} ->
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {keep_state, Connected#connected{buffer = Rest}, [{next_event, internal, Message} || Message <- Messages]};
        {error, Reason} ->
            {stop, {protocol_error, Reason}}
    end;
handle_event(info, {ClosedTag, Source}, _, #connected{transport_tags = {_, ClosedTag, _, Source}} = Connected) ->
    handle_disconnect(ClosedTag, Connected);
handle_event(info, {ErrorTag, Source, Reason}, _, #connected{transport_tags = {_, _, ErrorTag, Source}} = Connected) ->
    handle_disconnect({ErrorTag, Reason}, Connected);
handle_event(EventType, EventContent, disconnected, Data) ->
    disconnected(EventType, EventContent, Data);
handle_event(EventType, EventContent, authenticating, Data) ->
    authenticating(EventType, EventContent, Data);
handle_event(EventType, EventContent, connected, Data) ->
    connected(EventType, EventContent, Data).

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
terminate(Reason, _, #disconnected{callback = Callback, callback_state = State}) ->
    Callback:terminate(Reason, State);
terminate(Reason, _, #connected{callback = Callback, callback_state = State}) ->
    Callback:terminate(Reason, State).

%% @hidden
code_change(Vsn, State, #disconnected{} = Data, Extra) ->
    #disconnected{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:code_change(Vsn, CallbackState, Extra) of
        {ok, CallbackState1} ->
            {ok, State, Data#disconnected{callback_state = CallbackState1}};
        Other ->
            Other
    end;
code_change(Vsn, State, #connected{} = Data, Extra) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:code_change(Vsn, CallbackState, Extra) of
        {ok, CallbackState1} ->
            {ok, State, Data#connected{callback_state = CallbackState1}};
        Other ->
            Other
    end.


%% States

%%%% Disconnected

disconnected(internal, connect, Data) ->
    #disconnected{options = Options, callback = Callback, callback_state = CallbackState} = Data,
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
            {next_state, authenticating, send(Connect, #connected{
                options = Options,
                callback = Callback,
                callback_state = CallbackState,
                transport = Transport,
                transport_tags =  mqtt_transport:get_tags(Transport),
                keep_alive_timer = start_keep_alive_timer(KeepAlive)
            })};
        {error, Error} ->
            handle_disconnect(Error, Data)
    end;

disconnected(info, {timeout, Ref, reconnect}, #disconnected{reconnect_timer = Ref} = Data) ->
    {keep_state, Data#disconnected{reconnect_timer = undefined}, {next_event, internal, connect}};

disconnected({call, From}, _, Data) ->
    {keep_state, Data, {reply, From, {error, disconnected}}};

disconnected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).

%%%% Authenticating

authenticating(internal, #mqtt_connack{return_code = 0, session_present = Present}, Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:handle_connect(Present, CallbackState) of
        {ok, CallbackState1} ->
            {next_state, connected, Data#connected{callback_state = CallbackState1}};
        {ok, CallbackState1, Actions} ->
            {next_state, connected, handle_actions(Actions, Data#connected{callback_state = CallbackState1})};
        {stop, Reason} ->
            {stop, Reason}
    end;

authenticating(internal, #mqtt_connack{return_code = Code}, Data) ->
    handle_connect_error(Code, Data);

authenticating({call, _}, _, Data) ->
    {keep_state, Data, postpone};

authenticating(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%%%% Connected

connected(internal, #mqtt_publish{topic = Topic, message = Message, qos = 0}, Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    handle_callback_result(Callback:handle_publish(Topic, Message, CallbackState), Data);

connected(internal, #mqtt_publish{}, _Data) ->
    %% TODO: handle QoS 1 & 2
    exit(not_implemented);

connected(internal, #mqtt_suback{packet_id = Id, acks = Acks}, Data) ->
    #connected{pending_subscriptions = Pending} = Data,
    case maps:take(Id, Pending) of
        {Topics, Pending1} ->
            handle_suback(lists:zip(Topics, Acks), Data#connected{pending_subscriptions = Pending1});
        error ->
            {keep_state, Data}
    end;

connected(internal, #mqtt_unsuback{}, Data) ->
    {keep_state, Data};

connected({call, Call}, From, Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    handle_callback_result(Callback:handle_call(Call, From, CallbackState), Data);

connected(cast, Cast, Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    handle_callback_result(Callback:handle_cast(Cast, CallbackState), Data);

connected(info, Info, Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    handle_callback_result(Callback:handle_info(Info, CallbackState), Data);

connected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%% Extra handlers

handle_event(info, {timeout, Ref, keep_alive}, #connected{keep_alive_timer = {_, Ref}} = Data) ->
    {keep_state, send(#mqtt_pingreq{}, Data)};

handle_event(internal, #mqtt_pingresp{}, Data) ->
    {keep_state, Data};

handle_event(_, _, Data) ->
    {keep_state, Data}.

handle_connect_error(Code, Data) ->
    #connected{options = Options, callback = Callback, callback_state = CallbackState, transport = Transport} = Data,
    Error = case Code of
        1 -> unacceptable_protocol;
        2 -> identifier_rejected;
        3 -> server_unavailable;
        4 -> bad_username_or_password;
        5 -> not_authorized;
        _ -> {error, Code}
    end,
    case Callback:handle_connect_error(Error, CallbackState) of
        {reconnect, {backoff, Min, Max}, CallbackState1} ->
            _ = mqtt_transport:close(Transport),
            {next_state, disconnected, #disconnected{
                options = Options,
                callback = Callback,
                callback_state = CallbackState1,
                failures = 1,
                reconnect_timer = start_reconnect_timer(backoff(0, Min, Max))
            }};
        {stop, _} = Stop ->
            Stop
    end.

handle_disconnect(Error, #connected{} = Data) ->
    #connected{options = Options, callback = Callback, callback_state = CallbackState, transport = Transport} = Data,
    _ = mqtt_transport:close(Transport),
    case Callback:handle_disconnect(Error, CallbackState) of
        {reconnect, {backoff, Min, Max}, CallbackState1} ->
            {next_state, disconnected, #disconnected{
                options = Options,
                callback = Callback,
                callback_state = CallbackState1,
                failures = 1,
                reconnect_timer = start_reconnect_timer(backoff(0, Min, Max))
            }};
        {stop, _} = Stop ->
            Stop
    end;
handle_disconnect(Error, #disconnected{} = Data) ->
    #disconnected{callback = Callback, callback_state = CallbackState, failures = Failures} = Data,
    case Callback:handle_connect_error({transport_error, Error}, CallbackState) of
        {reconnect, {backoff, Min, Max}, CallbackState1} ->
            {keep_state, Data#disconnected{
                callback_state = CallbackState1,
                failures = Failures + 1,
                reconnect_timer = start_reconnect_timer(backoff(Failures, Min, Max))
            }};
        {stop, _} = Stop ->
            Stop
    end.

handle_suback(Acks, Data) ->
    handle_suback(Acks, [], Data).

handle_suback([{Topic, Ack} | Rest], ActionsAcc, #connected{} = Data) ->
    #connected{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:handle_subscribe_result(Topic, Ack, CallbackState) of
        {ok, CallbackState1} ->
            handle_suback(Rest, ActionsAcc, Data#connected{callback_state = CallbackState1});
        {ok, CallbackState1, Actions} ->
            handle_suback(Rest, [Actions | ActionsAcc], Data#connected{callback_state = CallbackState1});
        {stop, Reason} ->
            {stop, Reason}
    end;
handle_suback([], ActionsAcc, #connected{} = Data) ->
    {keep_state, handle_actions(lists:reverse(ActionsAcc), Data)}.

handle_callback_result(Result, #connected{} = Data) ->
    case Result of
        {ok, CallbackState1} ->
            {keep_state, Data#connected{callback_state = CallbackState1}};
        {ok, CallbackState1, Actions} ->
            {keep_state, handle_actions(Actions, Data#connected{callback_state = CallbackState1})};
        {stop, Reason} ->
            {stop, Reason}
    end.


%% Actions

handle_actions(Actions, #connected{} = Data) when is_list(Actions) ->
    lists:foldl(fun handle_actions/2, Data, Actions);
handle_actions({reply, From, Reply}, Data) ->
    gen_statem:reply(From, Reply),
    Data;
handle_actions({publish, Topic, Message}, #connected{} = Data) ->
    handle_action_publish(Topic, Message, 0, false, Data);
handle_actions({publish, Topic, Message, Options}, #connected{} = Data) ->
    QoS = maps:get(qos, Options, 0),
    Retain = maps:get(retain, Options, false),
    handle_action_publish(Topic, Message, QoS, Retain, Data);
handle_actions({subscribe, Topic}, #connected{} = Data) ->
    handle_action_subscribe([{Topic, 0}], Data);
handle_actions({subscribe, Topic, QoS}, #connected{} = Data) ->
    handle_action_subscribe([{Topic, QoS}], Data);
handle_actions({unsubscribe, Topic}, #connected{} = Data) ->
    handle_action_unsubscribe([Topic], Data).

handle_action_publish(Topic, Message, 0, Retain, Data) ->
    send(#mqtt_publish{
        retain = Retain,
        topic = Topic,
        message = Message
    }, Data);
handle_action_publish(_Topic, _Message, _QoS, _Retain, _Data) ->
    %% TODO: handle QoS 1 & 2
    exit(not_implemented).

handle_action_subscribe(Topics, Data) ->
    #connected{next_id = Id, pending_subscriptions = Pending} = Data,
    send(#mqtt_subscribe{
        packet_id = Id,
        topics = Topics
    }, Data#connected{
        next_id = Id + 1,
        pending_subscriptions = maps:put(Id, [Topic || {Topic, _Qos} <- Topics], Pending)
    }).

handle_action_unsubscribe(Topics, Data) ->
    #connected{next_id = Id} = Data,
    send(#mqtt_unsubscribe{
        packet_id = Id,
        topics = Topics
    }, Data#connected{next_id = Id + 1}).


%% Helpers

send(Packet, Data) ->
    #connected{transport = Transport, keep_alive_timer = KeepAliveTimer} = Data,
    ok = mqtt_transport:send(Transport, mqtt_packet:encode(Packet)),
    Data#connected{keep_alive_timer = restart_keep_alive_timer(KeepAliveTimer)}.

start_keep_alive_timer(0) ->
    undefined;
start_keep_alive_timer(Secs) ->
    Ref = erlang:start_timer(trunc(Secs * 1000), self(), keep_alive),
    {Secs, Ref}.

restart_keep_alive_timer(undefined) ->
    undefined;
restart_keep_alive_timer({Secs, Ref}) ->
    erlang:cancel_timer(Ref),
    start_keep_alive_timer(Secs).

start_reconnect_timer(Millisecs) ->
    erlang:start_timer(Millisecs, self(), reconnect).

backoff(Failures, Min, Max) ->
    Interval = 1000 * trunc(math:pow(2, Failures)),
    max(Min, min((rand:uniform(Interval) - 1), Max)).
