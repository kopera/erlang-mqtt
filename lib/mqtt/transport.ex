defmodule MQTT.Transport do
  @moduledoc false
  defdelegate new(type, socket), to: :mqtt_transport
end
