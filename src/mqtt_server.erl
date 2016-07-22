-module(mqtt_server).
-export([
    enter_loop/3
]).

-behaviour(gen_statem).
-export([
    init/1,
    handle_event/4,
    code_change/4,
    terminate/3
]).

-callback init(Args :: any(), Params :: init_parameters()) ->
      {ok, State :: any()}
    | {stop, Reason :: init_stop_reason()}.
-type init_parameters() :: #{
        protocol := binary(),
        clean_session := boolean(),
        client_id := binary(),
        username => binary(),
        password => binary(),
        last_will => #{
            topic := iodata(),
            message := iodata(),
            qos := mqtt_packet:qos(),
            retain := boolean()
        }
    }.
-type init_stop_reason() ::
      identifier_rejected
    | server_unavailable
    | bad_username_or_password
    | not_authorized
    | 6..255.

-callback handle_publish(Topic :: binary(), Message :: binary(), Opts :: map(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_subscribe(Topic :: binary(), QoS :: emqtt_packet:qos(), State :: any()) ->
      {ok, mqtt_packet:qos() | failed, State :: any()}
    | {ok, mqtt_packet:qos() | failed, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_unsubscribe(Topic :: binary(), State :: any()) ->
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
    | {reply, gen_statem:from(), term()}.

-include("../include/mqtt_packet.hrl").
-define(connect_timeout, 5). % seconds
-record(data, {
    callback :: module(),
    callback_state :: any(),
    transport :: emqtt_transport:transport(),
    transport_tags :: emqtt_transport:tags(),
    buffer = <<>> :: binary(),
    exit_timer = undefined :: {Secs :: pos_integer(), Tag :: term(), reference()} | undefined
}).

-spec enter_loop(module(), any(), emqtt_transport:transport()) -> no_return().
enter_loop(Module, Args, Transport) ->
    ok = mqtt_transport:set_opts(Transport, [{active, once}]),
    gen_statem:enter_loop(?MODULE, [], handle_event_function, authenticating, #data{
        callback = Module,
        callback_state = Args,
        transport = Transport,
        transport_tags =  mqtt_transport:get_tags(Transport),
        buffer = <<>>,
        exit_timer = start_timer(?connect_timeout, exit)
    }).


%% @hidden
init(_) ->
    exit(unexpected_call_to_init).

%% @hidden
handle_event(info, {DataTag, Source, Incoming}, State, #data{transport_tags = {DataTag, _, _, Source}} = Data) ->
    #data{transport = Transport, buffer = Buffer, exit_timer = ExitTimer} = Data,
    case decode_packets(<<Buffer/binary, Incoming/binary>>) of
        {ok, Messages, Rest} ->
            ok = mqtt_transport:set_opts(Transport, [{active, once}]),
            {keep_state, Data#data{
                buffer = Rest,
                exit_timer = case State of
                    authenticating -> ExitTimer;
                    _ -> restart_timer(ExitTimer)
                end
            }, [{next_event, internal, Message} || Message <- Messages]};
        {error, Reason} ->
            {stop, {protocol_error, Reason}}
    end;
handle_event(info, {ClosedTag, Source}, _, #data{transport_tags = {_, ClosedTag, _, Source}}) ->
    {stop, normal};
handle_event(info, {ErrorTag, Source, Reason}, _, #data{transport_tags = {_, _, ErrorTag, Source}}) ->
    {stop, Reason};
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
terminate(Reason, _, #data{callback = Callback, callback_state = State}) ->
    Callback:terminate(Reason, State).

%% @hidden
code_change(Vsn, State, #data{} = Data, Extra) ->
    #data{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:code_change(Vsn, CallbackState, Extra) of
        {ok, CallbackState1} ->
            {handle_event_function, State, Data#data{callback_state = CallbackState1}};
        Other ->
            Other
    end.


%% States


%%%% Authenticating

authenticating(internal, #mqtt_connect{protocol_level = Level} = Connect, Data) when Level =:= 3; Level =:= 4 ->
    #data{callback = Callback, callback_state = CallbackState, exit_timer = ExitTimer} = Data,
    stop_timer(ExitTimer),

    #mqtt_connect{
        protocol_name = Protocol,
        last_will = LastWill,
        clean_session = CleanSession,
        keep_alive = KeepAlive,
        client_id = ClientId,
        username = Username,
        password = Password
    } = Connect,
    Params = maps:filter(fun (_, V) -> V =/= undefined end, #{
        protocol => Protocol,
        last_will => case LastWill of
            undefined ->
                undefined;
            #mqtt_last_will{topic = Topic, message = Message, qos = QoS, retain = Retain} ->
                #{topic => Topic, message => Message, qos => QoS, retain => Retain}
        end,
        clean_session => CleanSession,
        client_id => ClientId,
        username => Username,
        password => Password
    }),
    case callback_result(Callback:init(CallbackState, Params)) of
        {ok, CallbackState1, Actions} ->
            {next_state, connected,
                handle_actions(Actions,
                    send(#mqtt_connack{return_code = 0},
                        Data#data{
                            callback_state = CallbackState1,
                            exit_timer = start_timer(1.5 * KeepAlive, exit)
                        }))};
        {stop, identifier_rejected} ->
            {stop, normal, send(#mqtt_connack{return_code = 2}, Data)};
        {stop, server_unavailable} ->
            {stop, normal, send(#mqtt_connack{return_code = 3}, Data)};
        {stop, bad_username_or_password} ->
            {stop, normal, send(#mqtt_connack{return_code = 4}, Data)};
        {stop, not_authorized} ->
            {stop, normal, send(#mqtt_connack{return_code = 5}, Data)};
        {stop, _} ->
            {stop, normal, Data}
    end;

authenticating(internal, #mqtt_connect{protocol_level = _}, Data) ->
    {stop, normal, send(#mqtt_connack{return_code = 1}, Data)};

authenticating({call, _}, _, Data) ->
    {keep_state, Data, postpone};

authenticating(cast, _, Data) ->
    {keep_state, Data, postpone};

authenticating(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%%%% Connected

connected(internal, #mqtt_publish{packet_id = Id, dup = Dup, qos = QoS, retain = Retain, topic = Topic, message = Message}, Data) ->
    handle_publish(Id, Topic, Message, #{dup => Dup, qos => QoS, retain => Retain}, Data);

connected(internal, #mqtt_subscribe{packet_id = Id, topics = Topics}, Data) ->
    handle_subscribe(Id, Topics, Data);

connected(internal, #mqtt_unsubscribe{packet_id = Id, topics = Topics}, Data) ->
    handle_unsubscribe(Id, Topics, Data);

connected({call, Call}, From, Data) ->
    callback(handle_call, [Call, From], Data);

connected(cast, Cast, Data) ->
    callback(handle_cast, [Cast], Data);

connected(info, Info, Data) ->
    callback(handle_info, [Info], Data);

connected(EventType, EventContent, Data) ->
    handle_event(EventType, EventContent, Data).


%% Extra handlers

handle_event(internal, #mqtt_pingreq{}, Data) ->
    {keep_state, send(#mqtt_pingresp{}, Data)};

handle_event(info, {timeout, Ref, exit}, #data{exit_timer = {_, _, Ref}}) ->
    {stop, normal};

handle_event(_, _, Data) ->
    {keep_state, Data}.

handle_publish(_Id, Topic, Message, #{qos := 0} = Opts, #data{} = Data) ->
    #data{callback = Callback, callback_state = CallbackState} = Data,
    case callback_result(Callback:handle_publish(Topic, Message, Opts, CallbackState)) of
        {ok, CallbackState1, Actions} ->
            {keep_state, handle_actions(Actions, Data#data{callback_state = CallbackState1})};
        {stop, Reason} ->
            {stop, Reason}
    end.

handle_subscribe(Id, Topics, Data) ->
    handle_subscribe(Id, Topics, [], [], Data).

handle_subscribe(Id, [{Topic, QoS} | Rest], ResultAcc, ActionsAcc, #data{} = Data) ->
    #data{callback = Callback, callback_state = CallbackState} = Data,
    case Callback:handle_subscribe(Topic, QoS, CallbackState) of
        {ok, Result, CallbackState1} ->
            handle_subscribe(Id, Rest, [Result | ResultAcc], ActionsAcc, Data#data{callback_state = CallbackState1});
        {ok, Result, CallbackState1, Actions} ->
            handle_subscribe(Id, Rest, [Result | ResultAcc], [Actions | ActionsAcc], Data#data{callback_state = CallbackState1});
        {stop, Reason} ->
            {stop, Reason}
    end;
handle_subscribe(Id, [], ResultAcc, ActionsAcc, #data{} = Data) ->
    {keep_state, handle_actions(lists:reverse(ActionsAcc), send(#mqtt_suback{
        packet_id = Id,
        acks = lists:reverse(ResultAcc)
    }, Data))}.

handle_unsubscribe(Id, Topics, Data) ->
    handle_unsubscribe(Id, Topics, [], Data).

handle_unsubscribe(Id, [Topic | Topics], ActionsAcc, Data) ->
    #data{callback = Callback, callback_state = CallbackState} = Data,
    case callback_result(Callback:handle_unsubscribe(Topic, CallbackState)) of
        {ok, CallbackState1, Actions} ->
            handle_unsubscribe(Id, Topics, [Actions | ActionsAcc], Data#data{callback_state = CallbackState1});
        {stop, Reason} ->
            {stop, Reason}
    end;
handle_unsubscribe(Id, [], ActionsAcc, #data{} = Data) ->
    {keep_state, handle_actions(lists:reverse(ActionsAcc), send(#mqtt_unsuback{
        packet_id = Id
    }, Data))}.


%% Actions

handle_actions(Actions, Data) when is_list(Actions) ->
    lists:foldl(fun handle_actions/2, Data, Actions);
handle_actions({reply, From, Reply}, #data{} = Data) ->
    gen_statem:reply(From, Reply),
    Data;
handle_actions({publish, Topic, Message}, Data) ->
    handle_action_publish(Topic, Message, 0, false, Data);
handle_actions({publish, Topic, Message, Options}, Data) ->
    QoS = maps:get(qos, Options, 0),
    Retain = maps:get(retain, Options, false),
    handle_action_publish(Topic, Message, QoS, Retain, Data).

handle_action_publish(Topic, Message, 0, Retain, Data) ->
    send(#mqtt_publish{
        retain = Retain,
        topic = Topic,
        message = Message
    }, Data);
handle_action_publish(_Topic, _Message, _QoS, _Retain, _Data) ->
    %% TODO: handle QoS 1 & 2
    exit(not_implemented).


%% Helpers

callback(Name, Args, Data) ->
    #data{callback = Callback, callback_state = CallbackState} = Data,
    case callback_result(erlang:apply(Callback, Name, Args ++ [CallbackState])) of
        {ok, CallbackState1, Actions} ->
            {keep_state, handle_actions(Actions, Data#data{callback_state = CallbackState1})};
        {stop, Reason} ->
            {stop, Reason}
    end.

callback_result({ok, State}) ->
    {ok, State, []};
callback_result({ok, State, Actions}) ->
    {ok, State, Actions};
callback_result({stop, Reason}) ->
    {stop, Reason}.

send(Packet, Data) ->
    #data{transport = Transport} = Data,
    ok = mqtt_transport:send(Transport, mqtt_packet:encode(Packet)),
    Data.

start_timer(0, _Tag) ->
    undefined;
start_timer(Secs, Tag) ->
    Ref = erlang:start_timer(trunc(Secs * 1000), self(), Tag),
    {Secs, Tag, Ref}.

stop_timer(undefined) ->
    undefined;
stop_timer({_, _, Ref}) ->
    erlang:cancel_timer(Ref),
    undefined.

restart_timer(undefined) ->
    undefined;
restart_timer({Secs, Tag, Ref}) ->
    erlang:cancel_timer(Ref),
    start_timer(Secs, Tag).
