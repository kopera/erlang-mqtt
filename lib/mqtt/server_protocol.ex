defmodule MQTT.ServerProtocol do
  @moduledoc false
  defdelegate init(module, args), to: :mqtt_server_protocol
  defdelegate handle_data(data, protocol), to: :mqtt_server_protocol
  defdelegate handle_call(call, from, protocol), to: :mqtt_server_protocol
  defdelegate handle_cast(cast, protocol), to: :mqtt_server_protocol
  defdelegate handle_info(info, protocol), to: :mqtt_server_protocol
  defdelegate terminate(reason, protocol), to: :mqtt_server_protocol
end
