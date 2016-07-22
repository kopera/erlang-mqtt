-module(mqtt_transport).
-export([
    new/2,
    open/4,
    open/5,
    send/2,
    recv/2,
    close/1,
    set_opts/2,
    get_tags/1
]).
-export_type([
    transport/0,
    host/0,
    port_number/0,
    tcp_options/0,
    ssl_options/0,
    tags/0
]).

-record(tcp, {
    socket :: port()
}).

-record(ssl, {
    socket :: ssl:sslsocket()
}).

-opaque transport() :: #tcp{} | #ssl{}.
-type host() :: inet:ip_address() | inet:hostname().
-type port_number() :: inet:port_number().
-type tcp_options() :: [gen_tcp:option()].
-type ssl_options() :: [ssl:connect_option()].


-spec new(tcp | ssl, port() | ssl:sslsocket()) -> transport().
new(tcp, Socket) when is_port(Socket) ->
    #tcp{socket = Socket};
new(ssl, Socket) ->
    #ssl{socket = Socket}.

-spec open(tcp | ssl, host(), port_number(), tcp_options() | ssl_options()) -> {ok, transport()} | {error, term()}.
open(Type, Host, Port, Options) ->
    open(Type, Host, Port, Options, infinity).

-spec open(tcp | ssl, host(), port_number(), tcp_options() | ssl_options(), timeout()) -> {ok, transport()} | {error, term()}.
open(tcp, Host, Port, Options, Timeout) ->
    open_tcp(Host, Port, Options, Timeout);
open(ssl, Host, Port, Options, Timeout) ->
    open_ssl(Host, Port, Options, Timeout).

open_tcp(Host, Port, Options, Timeout) ->
    case gen_tcp:connect(Host, Port, Options ++ [binary, {packet, raw}, {active, false}, {keepalive, true}], Timeout) of
        {ok, Socket} ->
            {ok, #tcp{socket = Socket}};
        {error, Error} ->
            {error, Error}
    end.

open_ssl(Host, Port, Options, Timeout) ->
    case ssl:connect(Host, Port, Options ++ [binary, {packet, raw}, {active, false}, {keepalive, true}], Timeout) of
        {ok, Socket} ->
            {ok, #ssl{socket = Socket}};
        {error, Error} ->
            {error, Error}
    end.

-spec send(transport(), iodata()) -> ok | {error, any()}.
send(#tcp{socket = Socket}, Data) ->
    gen_tcp:send(Socket, Data);
send(#ssl{socket = Socket}, Data) ->
    ssl:send(Socket, Data).

-spec recv(transport(), non_neg_integer()) -> {ok, binary()} | {error, any()}.
recv(#tcp{socket = Socket}, Length) ->
    gen_tcp:recv(Socket, Length);
recv(#ssl{socket = Socket}, Length) ->
    ssl:recv(Socket, Length).

-spec close(transport()) -> ok.
close(#tcp{socket = Socket}) ->
    gen_tcp:close(Socket);
close(#ssl{socket = Socket}) ->
    ssl:close(Socket),
    ok.

-spec set_opts(transport(), [inet:socket_setopt()]) -> ok | {error, any()}.
set_opts(#tcp{socket =  Socket}, Opts) ->
    inet:setopts(Socket, Opts);
set_opts(#ssl{socket =  Socket}, Opts) ->
    ssl:setopts(Socket, Opts).

-spec get_tags(transport()) -> tags().
-type tags() :: {tcp, tcp_closed, tcp_error, port_number()} | {ssl, ssl_closed, ssl_error, ssl:sslsocket()}.
get_tags(#tcp{socket = Socket}) ->
    {tcp, tcp_closed, tcp_error, Socket};
get_tags(#ssl{socket = Socket}) ->
    {ssl, ssl_closed, ssl_error, Socket}.
