defmodule MQTT.TestClient do

  @moduledoc false

  use MQTT.Client

  def start_link(opts) do
    MQTT.Client.start_link(
       __MODULE__, [], opts)
  end

  def init(_args) do
    {:ok, %{num_msgs_received: 0}}
  end

  def handle_connect(session_present, state) do
    send :test_client, {:connected, session_present}
    {:ok, state}
  end

  def handle_subscribe_result(topic, _status, state) do
    send :test_client, {:subscribed, topic}
    {:ok, state}
  end

  def handle_publish(topic, message, state) do
      send :test_client, {:publish, topic, message}
      {:ok, state}
  end

  def subscribe(pid, topic) do
    :mqtt_client.cast(pid, {:subscribe, topic})
  end

  def publish(pid, topic, msg) do
    :mqtt_client.cast(pid, {:publish, topic, msg})
  end

end
