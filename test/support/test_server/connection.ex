defmodule TestServer.Connection do
  use MQTT.Server

  def start_link(ref, ranch_socket, ranch_transport, options) do
    :proc_lib.start_link(__MODULE__, :init, [ref, ranch_socket, ranch_transport, options])
  end

  def stop(pid) do
    MQTT.Server.stop(pid, :normal, 500)
  end

  def init(ref, ranch_socket, ranch_transport, _options) do
    :ok = :proc_lib.init_ack({:ok, self()})
    :ok = :ranch.accept_ack(ref)
    transport = MQTT.Transport.new(ranch_transport.name(), ranch_socket)
    MQTT.Server.enter_loop(__MODULE__, [], transport)
  end

  def init(_args, %{protocol: <<"MQTT">>}) do
    {:ok, :my_state}
  end

  def init(_args, _) do
    {:stop, :unacceptable_protocol}
  end

  def handle_publish(_topic, _msg, _opts, state) do
    {:ok, state}
  end

  def handle_subscribe(_topic, _qos, state) do
    {:ok, :failed, state}
  end

  def handle_unsubscribe(_topic, state) do
    {:ok, state}
  end

  def handle_call(msg, from, state) do
    {:ok, state, {:reply, from, {:error, {:bad_call, msg}}}}
  end

  def handle_info(msg, state) do
    {:ok, state}
  end

  def handle_cast(msg, state) do
    {:ok, state}
  end

  def terminate(_reason, _state) do
    :ok
  end

  def code_change(_old, state, _extra) do
    {:ok, state}
  end
end
