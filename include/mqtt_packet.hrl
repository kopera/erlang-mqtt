-record(mqtt_last_will, {
    topic :: iodata(),
    message :: iodata(),
    qos :: mqtt_packet:qos(),
    retain :: boolean()
}).
-record(mqtt_connect, {
    protocol_name :: binary(),
    protocol_level :: 3 | 4,
    last_will :: undefined | #mqtt_last_will{},
    clean_session :: boolean(),
    keep_alive :: non_neg_integer(),
    client_id :: binary(),
    username :: undefined | binary(),
    password :: undefined | binary()
}).

-record(mqtt_connack, {
    session_present = false :: boolean(),
    return_code = 0 :: 0..255
}).

-record(mqtt_publish, {
    packet_id = undefined :: undefined | mqtt_packet:packet_id(),
    dup = false :: boolean(),
    qos = 0 :: mqtt_packet:qos(),
    retain = false :: boolean(),
    topic :: binary(),
    message :: binary()
}).

-record(mqtt_puback, {
    packet_id :: mqtt_packet:packet_id()
}).

-record(mqtt_pubrec, {
    packet_id :: mqtt_packet:packet_id()
}).

-record(mqtt_pubrel, {
    packet_id :: mqtt_packet:packet_id()
}).

-record(mqtt_pubcomp, {
    packet_id :: mqtt_packet:packet_id()
}).

-record(mqtt_subscribe, {
    packet_id :: mqtt_packet:packet_id(),
    topics :: [{Topic :: binary(), QoS :: mqtt_packet:qos()}]
}).

-record(mqtt_suback, {
    packet_id :: mqtt_packet:packet_id(),
    acks :: [mqtt_packet:qos() | failed]
}).

-record(mqtt_unsubscribe, {
    packet_id :: mqtt_packet:packet_id(),
    topics :: [binary()]
}).

-record(mqtt_unsuback, {
    packet_id :: mqtt_packet:packet_id()
}).

-record(mqtt_pingreq, {}).

-record(mqtt_pingresp, {}).

-record(mqtt_disconnect, {}).
