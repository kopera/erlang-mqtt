-module(mqtt_packet).
-export([
    decode/1,
    encode/1
]).
-export_type([
    packet/0,
    packet_id/0,
    qos/0
]).


-include("../include/mqtt_packet.hrl").
-type packet() ::
      #mqtt_connect{}
    | #mqtt_connack{}
    | #mqtt_publish{}
    | #mqtt_puback{}
    | #mqtt_pubrec{}
    | #mqtt_pubrel{}
    | #mqtt_pubcomp{}
    | #mqtt_subscribe{}
    | #mqtt_suback{}
    | #mqtt_unsubscribe{}
    | #mqtt_unsuback{}
    | #mqtt_pingreq{}
    | #mqtt_pingresp{}
    | #mqtt_disconnect{}.
-type packet_id() :: 0..65535.
-type qos() :: 0 | 1 | 2.


-spec decode(binary()) -> {ok, packet(), binary()} | {error, parse_error()} | incomplete.
-type parse_error() :: atom().
decode(<<Header:1/binary, 0:1, L:7, Data/binary>>) ->
    parse(Header, L, Data);
decode(<<Header:1/binary, 1:1, L1:7, 0:1, L2:7, Data/binary>>) ->
    parse(Header, L1 + (L2 bsl 7), Data);
decode(<<Fixed:1/binary, 1:1, L1:7, 1:1, L2:7, 0:1, L3:7, Data/binary>>) ->
    parse(Fixed, L1 + (L2 bsl 7) + (L3 bsl 14), Data);
decode(<<Fixed:1/binary, 1:1, L1:7, 1:1, L2:7, 1:1, L3:7, 0:1, L4:7, Data/binary>>) ->
    parse(Fixed, L1 + (L2 bsl 7) + (L3 bsl 14) + (L4 bsl 21), Data);
decode(<<_:8/binary, _/binary>>) ->
    {error, malformed_length};
decode(Data) when is_binary(Data) ->
    incomplete.

%% @private
parse(Header, Length, Data) ->
    case Data of
        <<Payload:Length/binary, Rest/binary>> ->
            case parse_packet(Header, Payload) of
                {error, _} = Error -> Error;
                Packet -> {ok, Packet, Rest}
            end;
        _ ->
            incomplete
    end.

%% @private
%% CONNECT
parse_packet(<<1:4, 0:4>>, <<
    ProtoNameLen:16, ProtoName:ProtoNameLen/binary,
    Level:8,
    HasUsername:1, HasPassword:1, LastWillFlags:4/bits, CleanSession:1, 0:1, % Flags
    KeepAlive:16,
    ClientIdLen:16, ClientId:ClientIdLen/binary,
    Payload/binary>>) ->
    case parse_last_will(LastWillFlags, Payload) of
        {error, _} = Error ->
            Error;
        {LastWill, Rest} ->
            case parse_optional_string(HasUsername, Rest) of
                {error, _} = Error ->
                    Error;
                {Username, Rest1} ->
                    case parse_optional_string(HasPassword, Rest1) of
                        {error, _} = Error ->
                            Error;
                        {Password, <<>>} ->
                            #mqtt_connect{
                                protocol_name = ProtoName,
                                protocol_level = Level,
                                last_will = LastWill,
                                clean_session = CleanSession =:= 1,
                                keep_alive = KeepAlive,
                                client_id = ClientId,
                                username = Username,
                                password = Password
                            };
                        {_, _} ->
                            {error, malformed_packet}
                    end
            end
    end;
%% CONNACK
parse_packet(<<2:4, 0:4>>, <<0:7, SessionPresent:1, ReturnCode:8>>) ->
    #mqtt_connack{session_present = SessionPresent =:= 1, return_code = ReturnCode};
%% PUBLISH
parse_packet(<<3:4, Dup:1, QoS:2, Retain:1>>, <<TopicLen:16, Topic:TopicLen/binary, Payload/binary>>) when QoS =:= 0 ->
    case parse_topic(Topic) of
        {error, _} = Error ->
            Error;
        T ->
            #mqtt_publish{
                dup = Dup =:= 1,
                qos = QoS,
                retain = Retain =:= 1,
                topic = T,
                message = Payload
            }
    end;
parse_packet(<<3:4, Dup:1, QoS:2, Retain:1>>, <<TopicLen:16, Topic:TopicLen/binary, PacketId:16, Payload/binary>>) when QoS >= 1 ->
    case parse_topic(Topic) of
        {error, _} = Error ->
            Error;
        T ->
            #mqtt_publish{
                dup = Dup =:= 1,
                qos = QoS,
                retain = Retain =:= 1,
                topic = T,
                packet_id = PacketId,
                message = Payload
            }
    end;
%% PUBACK
parse_packet(<<4:4, 0:4>>, <<PacketId:16>>) ->
    #mqtt_puback{packet_id = PacketId};
%% PUBREC
parse_packet(<<5:4, 0:4>>, <<PacketId:16>>) ->
    #mqtt_pubrec{packet_id = PacketId};
%% PUBREL
parse_packet(<<6:4, 2#0010:4>>, <<PacketId:16>>) ->
    #mqtt_pubrel{packet_id = PacketId};
%% PUBCOMP
parse_packet(<<7:4, 0:4>>, <<PacketId:16>>) ->
    #mqtt_pubcomp{packet_id = PacketId};
%% SUBSCRIBE
parse_packet(<<8:4, 2#0010:4>>, <<PacketId:16, Topics/binary>>) ->
    case parse_topics(Topics) of
        {error, _} = Error -> Error;
        T -> #mqtt_subscribe{packet_id = PacketId, topics = T}
    end;
%% SUBACK
parse_packet(<<9:4, 0:4>>, <<PacketId:16, Acks/binary>>) ->
    #mqtt_suback{packet_id = PacketId, acks = parse_acks(Acks)};
%% UNSUBSCRIBE
parse_packet(<<10:4, 2#0010:4>>, <<PacketId:16, Topics/binary>>) ->
    case parse_topics(Topics) of
        {error, _} = Error -> Error;
        T -> #mqtt_unsubscribe{packet_id = PacketId, topics = T}
    end;
%% UNSUBACK
parse_packet(<<11:4, 0:4>>, <<PacketId:16>>) ->
    #mqtt_unsuback{packet_id = PacketId};
%% PINGREQ
parse_packet(<<12:4, 0:4>>, <<>>) ->
    #mqtt_pingreq{};
%% PINGRESP
parse_packet(<<13:4, 0:4>>, <<>>) ->
    #mqtt_pingresp{};
%% DISCONNECT
parse_packet(<<14:4, 0:4>>, <<>>) ->
    #mqtt_disconnect{};
%% ...
parse_packet(_, _) ->
    {error, malformed_packet}.

%% @private
parse_last_will(<<_:1, _:2, 0:1>>, Payload) ->
    {undefined, Payload};
parse_last_will(<<Retain:1, QoS:2, 1:1>>, <<TopicLen:16, Topic:TopicLen/binary, MessageLen:16, Message:MessageLen/binary, Rest/binary>>) ->
    case parse_topic(Topic) of
        {error, _} = Error ->
            Error;
        T ->
            {#mqtt_last_will{
                topic = T,
                message = Message,
                qos = QoS,
                retain = Retain =:= 1
            }, Rest}
    end;
parse_last_will(<<_:1, _:2, _:1>>, _) ->
    {error, malformed_will}.

%% @private
parse_string(<<Len:16, Str:Len/binary, Rest/binary>>) ->
    {Str, Rest};
parse_string(_) ->
    {error, malformed_string}.

%% @private
parse_optional_string(0, Payload) ->
    {undefined, Payload};
parse_optional_string(1, Payload) ->
    parse_string(Payload).

%% @private
parse_topic(<<>>) ->
    {error, malformed_topic};
parse_topic(Topic) ->
    %% TODO: validate topic
    Topic.

%% @private
parse_topics(Topics) ->
    parse_topics(Topics, []).

%% @private
parse_topics(<<Len:16, Topic:Len/binary, 0:6, QoS:2, Rest/binary>>, Acc) ->
    case parse_topic(Topic) of
        {error, _} = Error -> Error;
        T -> parse_topics(Rest, [{T, QoS} | Acc])
    end;
parse_topics(<<>>, Topics) ->
    lists:reverse(Topics);
parse_topics(_, _) ->
    {error, malformed_packet}.

%% @private
parse_acks(Acks) ->
    parse_acks(Acks, []).

%% @private
parse_acks(<<16#80:8, Rest/binary>>, Acks) ->
    parse_acks(Rest, [failed | Acks]);
parse_acks(<<_:6, QoS:2, Rest/binary>>, Acks) ->
    parse_acks(Rest, [QoS | Acks]);
parse_acks(<<>>, Acks) ->
    lists:reverse(Acks);
parse_acks(_, _) ->
    {error, malformed_packet}.


-spec encode(packet()) -> iodata().
encode(#mqtt_connect{
            protocol_name = Name,
            protocol_level = Level,
            last_will = LastWill,
            clean_session = CleanSession,
            keep_alive = KeepAlive,
            client_id = ClientId,
            username = Username,
            password = Password
        }) ->
    Payload = [
        encode_string(Name),
        <<Level:8>>,
        << %% Flags
            (encode_bool(Username =/= undefined)):1,
            (encode_bool(Password =/= undefined)):1,
            (encode_last_will_flags(LastWill)):4,
            (encode_bool(CleanSession)):1,
            0:1 % Reserved
        >>,
        <<KeepAlive:16>>,
        encode_string(ClientId),
        encode_last_will(LastWill),
        encode_optional_string(Username),
        encode_optional_string(Password)
    ],
    PayloadLength = encode_length(iolist_size(Payload)),
    [<<1:4, 0:4>>, PayloadLength, Payload];
encode(#mqtt_connack{session_present = SessionPresent, return_code = ReturnCode}) ->
    <<2:4, 0:4, 2:8, 0:7, (encode_bool(SessionPresent)):1, ReturnCode:8>>;
encode(#mqtt_publish{dup = Dup, qos = QoS, retain = Retain, topic = Topic, packet_id = PacketId, message = Message}) ->
    Payload = [encode_topic(Topic), if
        QoS =:= 0 -> <<>>;
        QoS >= 1 -> <<PacketId:16>>
    end, Message],
    PayloadLength = encode_length(iolist_size(Payload)),
    [<<3:4, (encode_bool(Dup)):1, QoS:2, (encode_bool(Retain)):1>>, PayloadLength, Payload];
encode(#mqtt_puback{packet_id = PacketId}) ->
    <<4:4, 0:4, 2:8, PacketId:16>>;
encode(#mqtt_pubrec{packet_id = PacketId}) ->
    <<5:4, 0:4, 2:8, PacketId:16>>;
encode(#mqtt_pubrel{packet_id = PacketId}) ->
    <<6:4, 0:4, 2:8, PacketId:16>>;
encode(#mqtt_pubcomp{packet_id = PacketId}) ->
    <<7:4, 0:4, 2:8, PacketId:16>>;
encode(#mqtt_subscribe{packet_id = PacketId, topics = Topics}) ->
    Payload = [<<PacketId:16>>, encode_topics(Topics, [])],
    PayloadLength = encode_length(iolist_size(Payload)),
    [<<8:4, 2#0010:4>>, PayloadLength, Payload];
encode(#mqtt_suback{packet_id = PacketId, acks = Acks}) ->
    Payload = [<<PacketId:16>>, encode_acks(Acks)],
    PayloadLength = encode_length(iolist_size(Payload)),
    [<<9:4, 0:4>>, PayloadLength, Payload];
encode(#mqtt_unsubscribe{packet_id = PacketId, topics = Topics}) ->
    Payload = [<<PacketId:16>>, encode_topics(Topics)],
    PayloadLength = encode_length(iolist_size(Payload)),
    [<<10:4, 2#0010>>, PayloadLength, Payload];
encode(#mqtt_unsuback{packet_id = PacketId}) ->
    <<11:4, 0:4, 2:8, PacketId:16>>;
encode(#mqtt_pingreq{}) ->
    <<12:4, 0:4, 0>>;
encode(#mqtt_pingresp{}) ->
    <<13:4, 0:4, 0>>;
encode(#mqtt_disconnect{}) ->
    <<14:4, 0:4, 0>>.

%% @private
encode_length(L) when L < 16#80 -> <<0:1, L:7>>;
encode_length(L) -> <<1:1, (L rem 16#80):7, (encode_length(L div 16#80))/binary>>.

%% @private
encode_bool(false) -> 0;
encode_bool(true) -> 1.

%% @private
encode_string(Str) ->
    Length = iolist_size(Str),
    if
        Length =< 65536 ->
            [<<Length:16>>, Str];
        Length > 65536 ->
            error(badarg, [Str])
    end.

%% @private
encode_optional_string(undefined) ->
    <<>>;
encode_optional_string(Str) ->
    encode_string(Str).

%% @private
encode_last_will_flags(undefined) ->
    0;
encode_last_will_flags(#mqtt_last_will{qos = QoS, retain = Retain}) ->
    1 bor (QoS bsl 1) bor (encode_bool(Retain) bsl 3).

%% @private
encode_last_will(undefined) ->
    <<>>;
encode_last_will(#mqtt_last_will{topic = Topic, message = Message}) ->
    [encode_string(Topic), encode_string(Message)].

%% @private
encode_topics(Topics) ->
    encode_topics(Topics, []).

%% @private
encode_topics([{Topic, QoS} | Rest], Acc) ->
    encode_topics(Rest, [[encode_topic(Topic), <<0:6, QoS:2>>] | Acc]);
encode_topics([Topic | Rest], Acc) ->
    encode_topics(Rest, [encode_topic(Topic) | Acc]);
encode_topics([], Acc) ->
    lists:reverse(Acc).

%% @private
encode_topic(Topic) ->
    Length = iolist_size(Topic),
    [<<Length:16>>, Topic].

%% @private
encode_acks(Acks) ->
    encode_acks(Acks, []).

%% @private
encode_acks([QoS | Rest], Acc) when is_integer(QoS), QoS >= 0, QoS =< 2 ->
    encode_acks(Rest, [<<0:6, QoS:2>> | Acc]);
encode_acks([failed | Rest], Acc) ->
    encode_acks(Rest, [<<128:8>> | Acc]);
encode_acks([], Acc) ->
    Acc.
