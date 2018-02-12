%% @private
-module(mqtt_server_protocol).
-export([
    init/2,
    handle_data/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-include("../include/mqtt_packet.hrl").
-define(connect_timeout, 5000).

-record(protocol, {
    state :: connecting | connected,
    callback :: module(),
    callback_state :: any(),
    buffer = <<>> :: binary(),
    exit_timer :: timer() | undefined
}).

-type timer() :: {MilliSecs :: pos_integer(), Tag :: term(), reference()}.
-type protocol() :: #protocol{}.
-type result() ::
      {ok, protocol(), [action()]}
    | {stop, protocol(), [action()]}.
-type action() ::
      {send, iodata()}
    | {reply, gen_server:from(), Reply :: any()}.


-spec init(module(), any()) -> protocol().
init(Callback, CallbackState) ->
    #protocol{
        state = connecting,
        callback = Callback,
        callback_state = CallbackState,
        buffer = <<>>,
        exit_timer = start_timer(?connect_timeout, exit)
    }.

-spec handle_data(binary(), protocol()) -> result().
handle_data(Incoming, #protocol{buffer = Buffer, exit_timer = ExitTimer} = Protocol) ->
    case decode_packets(<<Buffer/binary, Incoming/binary>>) of
        {ok, Packets, Rest} ->
            handle_packets(Packets, Protocol#protocol{
                buffer = Rest,
                exit_timer = restart_timer(ExitTimer)
            });
        {error, Reason} ->
            {stop, {protocol_error, Reason}, []}
    end.

-spec handle_call(term(), gen_server:from(), protocol()) -> result().
handle_call(Request, From, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_call(Request, From, CallbackState) of
        {ok, CallbackState1} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, []};
        {ok, CallbackState1, Actions} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, encode_actions(actions(Actions))};
        {stop, Reason} ->
            {stop, Reason, []}
    end.

-spec handle_cast(term(), protocol()) -> result().
handle_cast(Cast, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_cast(Cast, CallbackState) of
        {ok, CallbackState1} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, []};
        {ok, CallbackState1, Actions} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, encode_actions(actions(Actions))};
        {stop, Reason} ->
            {stop, Reason, []}
    end.

-spec handle_info(any(), protocol()) -> result().
handle_info({timeout, Ref, exit}, #protocol{exit_timer = {_, _, Ref}}) ->
    {stop, normal, []};
handle_info(Info, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_info(Info, CallbackState) of
        {ok, CallbackState1} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, []};
        {ok, CallbackState1, Actions} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, encode_actions(actions(Actions))};
        {stop, Reason} ->
            {stop, Reason, []}
    end.

terminate(Reason, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    Callback:terminate(Reason, CallbackState).


handle_packets(Packets, Protocol) ->
    handle_packets(Packets, [], Protocol).

handle_packets([Packet | Rest], ActionsAcc, Protocol) ->
    case handle_packet(Packet, Protocol) of
        {ok, Protocol1, Actions} ->
            handle_packets(Rest, lists:reverse(Actions, ActionsAcc), Protocol1);
        {stop, Protocol1, Actions} ->
            {stop, Protocol1, lists:reverse(ActionsAcc, Actions)}
    end;
handle_packets([], ActionsAcc, Protocol) ->
    {ok, Protocol, lists:reverse(ActionsAcc)}.


-spec handle_packet(mqtt_packet:packet(), protocol()) -> result().
handle_packet(Packet, #protocol{state = connecting} = Protocol) ->
    connecting(Packet, Protocol);
handle_packet(Packet, #protocol{state = connected} = Protocol) ->
    connected(Packet, Protocol).

connecting(#mqtt_connect{protocol_level = Level} = Connect, Protocol) when Level =:= 3; Level =:= 4 ->
    #protocol{callback = Callback, callback_state = CallbackState, exit_timer = ExitTimer} = Protocol,
    #mqtt_connect{
        protocol_name = ProtocolName,
        last_will = LastWill,
        clean_session = CleanSession,
        keep_alive = KeepAlive,
        client_id = ClientId,
        username = Username,
        password = Password
    } = Connect,
    Params = maps:filter(fun (_, V) -> V =/= undefined end, #{
        protocol => ProtocolName,
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
    stop_timer(ExitTimer),
    case Callback:init(CallbackState, Params) of
        {ok, CallbackState1} ->
            {ok, Protocol#protocol{
                state = connected,
                callback_state = CallbackState1,
                exit_timer = start_timer(trunc(1000 * 1.5 * KeepAlive), exit)
            }, [encode_send(#mqtt_connack{return_code = 0})]};
        {ok, CallbackState1, Actions} ->
            {ok, Protocol#protocol{
                state = connected,
                callback_state = CallbackState1,
                exit_timer = start_timer(trunc(1000 * 1.5 * KeepAlive), exit)
            }, [encode_send(#mqtt_connack{return_code = 0}) | encode_actions(actions(Actions))]};
        {stop, unacceptable_protocol} ->
            {stop, normal, [encode_send(#mqtt_connack{return_code = 1})]};
        {stop, identifier_rejected} ->
            {stop, normal, [encode_send(#mqtt_connack{return_code = 2})]};
        {stop, server_unavailable} ->
            {stop, normal, [encode_send(#mqtt_connack{return_code = 3})]};
        {stop, bad_username_or_password} ->
            {stop, normal, [encode_send(#mqtt_connack{return_code = 4})]};
        {stop, not_authorized} ->
            {stop, normal, [encode_send(#mqtt_connack{return_code = 5})]};
        {stop, Reason} ->
            {stop, Reason, []}
    end;
connecting(#mqtt_connect{protocol_level = _}, Protocol) ->
    stop_timer(Protocol#protocol.exit_timer),
    {stop, normal, [encode_send(#mqtt_connack{return_code = 1})]};
connecting(_, Protocol) ->
    stop_timer(Protocol#protocol.exit_timer),
    {stop, protocol_error, []}.


connected(#mqtt_publish{packet_id = Id, dup = Dup, qos = QoS, retain = Retain, topic = Topic, message = Message}, Protocol) ->
    handle_publish(Id, Topic, Message, #{dup => Dup, qos => QoS, retain => Retain}, Protocol);
connected(#mqtt_subscribe{packet_id = Id, topics = Topics}, Protocol) ->
    handle_subscribe(Id, Topics, Protocol);
connected(#mqtt_unsubscribe{topics = Topics}, Protocol) ->
    handle_unsubscribe(Topics, Protocol);
connected(#mqtt_pingreq{}, Protocol) ->
    {ok, Protocol, [encode_send(#mqtt_pingresp{})]}.


handle_publish(_Id, Topic, Message, #{qos := 0} = Opts, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_publish(Topic, Message, Opts, CallbackState) of
        {ok, CallbackState1} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, []};
        {ok, CallbackState1, Actions} ->
            {ok, Protocol#protocol{
                callback_state = CallbackState1
            }, encode_actions(actions(Actions))};
        {stop, Reason} ->
            {stop, Reason, []}
    end.

handle_subscribe(Id, Topics, Protocol) ->
    handle_subscribe(Id, Topics, [], [], Protocol).

handle_subscribe(Id, [{Topic, QoS} | Rest], ResultAcc, ActionsAcc, #protocol{} = Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_subscribe(Topic, QoS, CallbackState) of
        {ok, Result, CallbackState1} ->
            handle_subscribe(Id, Rest, [Result | ResultAcc], ActionsAcc, Protocol#protocol{
                callback_state = CallbackState1
            });
        {ok, Result, CallbackState1, Actions} ->
            handle_subscribe(Id, Rest, [Result | ResultAcc], lists:reverse(actions(Actions), ActionsAcc), Protocol#protocol{
                callback_state = CallbackState1
            });
        {stop, Reason} ->
            {stop, Reason, []}
    end;
handle_subscribe(Id, [], ResultAcc, ActionsAcc, #protocol{} = Protocol) ->
    {ok, Protocol, [
        encode_send(#mqtt_suback{packet_id = Id, acks = lists:reverse(ResultAcc)}) |
        encode_actions(lists:reverse(ActionsAcc))
    ]}.

handle_unsubscribe(Topics, Protocol) ->
    handle_unsubscribe(Topics, [], Protocol).

handle_unsubscribe([Topic | Topics], ActionsAcc, Protocol) ->
    #protocol{callback = Callback, callback_state = CallbackState} = Protocol,
    case Callback:handle_unsubscribe(Topic, CallbackState) of
        {ok, CallbackState1} ->
            handle_unsubscribe(Topics, ActionsAcc, Protocol#protocol{
                callback_state = CallbackState1
            });
        {ok, CallbackState1, Actions} ->
            handle_unsubscribe(Topics, lists:reverse(actions(Actions), ActionsAcc), Protocol#protocol{
                callback_state = CallbackState1
            });
        {stop, Reason} ->
            {stop, Reason, []}
    end;
handle_unsubscribe([], ActionsAcc, #protocol{} = Protocol) ->
    {ok, Protocol, encode_actions(lists:reverse(ActionsAcc))}.


%% Decoding

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

%% Encoding

actions(Actions) when is_list(Actions) ->
    Actions;
actions(Action) ->
    [Action].

encode_actions(Actions) ->
    [encode_action(Action) || Action <- Actions].

encode_action({publish, Topic, Message}) ->
    encode_publish(Topic, Message, 0, false);
encode_action({publish, Topic, Message, Options}) ->
    QoS = maps:get(qos, Options, 0),
    Retain = maps:get(retain, Options, false),
    encode_publish(Topic, Message, QoS, Retain);
encode_action({reply, _From, _Reply} = Reply) ->
    Reply.

encode_publish(Topic, Message, 0, Retain) ->
    encode_send(#mqtt_publish{
        retain = Retain,
        topic = Topic,
        message = Message
    });
encode_publish(_Topic, _Message, _QoS, _Retain) ->
    %% TODO: handle QoS 1 & 2
    exit(not_implemented).

encode_send(Packet) ->
    {send, mqtt_packet:encode(Packet)}.

%% Timers

start_timer(0, _Tag) ->
    undefined;
start_timer(MilliSecs, Tag) ->
    Ref = erlang:start_timer(MilliSecs, self(), Tag),
    {MilliSecs, Tag, Ref}.

stop_timer(undefined) ->
    undefined;
stop_timer({_, _, Ref}) ->
    erlang:cancel_timer(Ref),
    undefined.

restart_timer(undefined) ->
    undefined;
restart_timer({MilliSecs, Tag, Ref}) ->
    erlang:cancel_timer(Ref),
    start_timer(MilliSecs, Tag).
