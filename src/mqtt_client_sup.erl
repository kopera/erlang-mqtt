%% @private
-module(mqtt_client_sup).
-export([
    start_link/0
]).
-export([
    start_connection/2,
    stop_connection/1
]).

-behaviour(supervisor).
-export([
    init/1
]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


-spec start_connection(pid(), mqtt_client:start_options()) -> {ok, pid(), integer()} | {error, string()}.
start_connection(Owner, Opts) ->
    supervisor:start_child(?MODULE, [Owner, Opts]).


% -spec stop_connection(ble:connection()) -> ok.
stop_connection(Connection) ->
    mqtt_client:close(Connection).


init([]) ->
    Flags = #{strategy => simple_one_for_one, intensity => 10, period => 5},
    Children = [
        #{
            id => mqtt_client,
            type => worker,
            start => {mqtt_client, start_link, []},
            restart => temporary
        }
    ],
    {ok, {Flags, Children}}.
