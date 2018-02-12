%% @private
-module(mqtt_client_sup).
-export([
    start_link/0
]).
-export([
    start_connection/2
]).

-behaviour(supervisor).
-export([
    init/1
]).


start_connection(Owner, Opts) ->
    supervisor:start_child(?MODULE, [Owner, Opts]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


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
