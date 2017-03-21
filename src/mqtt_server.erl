-module(mqtt_server).
-export([
    enter_loop/3,
    stop/1,
    stop/3
]).

-behaviour(gen_server).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-callback init(Args :: any(), Params :: init_parameters()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
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
-callback handle_subscribe(Topic :: binary(), QoS :: mqtt_packet:qos(), State :: any()) ->
      {ok, mqtt_packet:qos() | failed, State :: any()}
    | {ok, mqtt_packet:qos() | failed, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_unsubscribe(Topic :: binary(), State :: any()) ->
      {ok, State :: any()}
    | {ok, State :: any(), action() | [action()]}
    | {stop, Reason :: term()}.
-callback handle_call(Call :: any(), From :: gen_server:from(), State :: any()) ->
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
    | {publish, Topic :: iodata(), Message :: iodata(), #{qos => mqtt_packet:qos(), retain => boolean()}}.

-record(state, {
    transport :: mqtt_transport:transport(),
    transport_tags :: mqtt_transport:tags(),
    protocol :: mqtt_server_protocol:protocol()
}).


-spec enter_loop(module(), any(), mqtt_transport:transport()) -> no_return().
enter_loop(Callback, CallbackArgs, Transport) ->
    ok = mqtt_transport:set_opts(Transport, [{active, once}]),
    gen_server:enter_loop(?MODULE, [], #state{
        transport = Transport,
        transport_tags =  mqtt_transport:get_tags(Transport),
        protocol = mqtt_server_protocol:init(Callback, CallbackArgs)
    }).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec stop(pid(), term(), timeout()) -> ok.
stop(Pid, Reason, Timeout) ->
    gen_server:stop(Pid, Reason, Timeout).

%% @hidden
init(_) ->
    exit(unexpected_call_to_init).

%% @hidden
handle_call(Request, From, State) ->
    call_protocol(handle_call, [Request, From], State).

%% @hidden
handle_cast(Cast, State) ->
    call_protocol(handle_cast, [Cast], State).

%% @hidden
handle_info({DataTag, Source, Incoming}, #state{transport = Transport, transport_tags = {DataTag, _, _, Source}} = State) ->
    ok = mqtt_transport:set_opts(Transport, [{active, once}]),
    call_protocol(handle_data, [Incoming], State);
handle_info({ClosedTag, Source}, #state{transport_tags = {_, ClosedTag, _, Source}}) ->
    {stop, normal};
handle_info({ErrorTag, Source, Reason}, #state{transport_tags = {_, _, ErrorTag, Source}}) ->
    {stop, Reason};
handle_info(Info, State) ->
    call_protocol(handle_info, [Info], State).

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% @hidden
terminate(Reason, #state{protocol = Protocol}) ->
    mqtt_server_protocol:terminate(Reason, Protocol).


call_protocol(Function, Args, #state{protocol = Protocol} = State) ->
    case erlang:apply(mqtt_server_protocol, Function, Args ++ [Protocol]) of
        {ok, Protocol1, Actions} ->
            {noreply, handle_actions(Actions, State#state{protocol = Protocol1})};
        {stop, Reason, Actions} ->
            {stop, Reason, handle_actions(Actions, State)}
    end.

handle_actions([{send, Data} | Rest], #state{transport = Transport} = State) ->
    ok = mqtt_transport:send(Transport, Data),
    handle_actions(Rest, State);
handle_actions([{reply, To, Reply} | Rest], #state{} = State) ->
    gen_server:reply(To, Reply),
    handle_actions(Rest, State);
handle_actions([], State) ->
    State.
