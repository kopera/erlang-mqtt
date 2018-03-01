%% @private
-module(mqtt_sup).
-export([
    start_link/0
]).

-behaviour(supervisor).
-export([
    init/1
]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


init([]) ->
    Flags = #{strategy => one_for_one, intensity => 0, period => 1},
    Children = [
        #{
            id => mqtt_client_sup,
            type => supervisor,
            start => {mqtt_client_sup, start_link, []},
            restart => permanent
        }
    ],
    {ok, {Flags, Children}}.
