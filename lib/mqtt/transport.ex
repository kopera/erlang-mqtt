defmodule MQTT.Transport do
  defdelegate new(type, socket), to: :mqtt_transport
end
