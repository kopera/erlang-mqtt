defmodule MQTT.Client do
  @moduledoc """
  An MQTT client.
  """

  @doc "Connect to an mqtt broker."
  defdelegate connect(opts), to: :mqtt_client

  @doc "Disconnect from an mqtt broker."
  defdelegate disconnect(connection), to: :mqtt_client

  @doc "Synchronously subscribe to a set of topics."
  defdelegate subscribe(connection, topics), to: :mqtt_client

  @doc "Unsubscribe from a set of topics."
  defdelegate unsubscribe(connection, topics), to: :mqtt_client

  @doc "Publish a message to a topic."
  defdelegate publish(connection, topic, message), to: :mqtt_client

  @doc "Publish a message to a topic."
  defdelegate publish(connection, topic, message, opts), to: :mqtt_client

end
