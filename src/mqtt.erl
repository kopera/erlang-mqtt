-module(mqtt).
-export_type([
    topic/0,
    qos/0
]).

-type topic() :: mqtt_packet:topic().
-type qos() :: mqtt_packet:qos().
