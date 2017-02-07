defmodule MQTT.Server do
  @moduledoc """
  A behaviour module for implementing an MQTT "broker".
  """

  @callback init(args :: any, params :: init_parameters) ::
    {:ok, state} |
    {:stop, reason :: init_stop_reason} when state: any

  @callback handle_publish(topic :: String.t, message :: binary, opts :: map, state) ::
    {:ok, state} |
    {:ok, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback handle_subscribe(topic :: String.t, qos :: :mqtt_packet.qos, state) ::
    {:ok, :mqtt_packet.qos | :failed, state} |
    {:ok, :mqtt_packet.qos | :failed, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback handle_unsubscribe(topic :: binary, state) ::
    {:ok, state} |
    {:ok, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback handle_call(call :: any, from :: :gen_statem.from, state) ::
    {:ok, state} |
    {:ok, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback handle_cast(cast :: any, state) ::
    {:ok, state} |
    {:ok, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback handle_info(info :: any, state) ::
    {:ok, state} |
    {:ok, state, action | [action]} |
    {:stop, reason :: term} when state: any

  @callback terminate(:normal | :shutdown | {:shutdown, term} | term, state) ::
    any when state: any

  @callback code_change(old_vsn, state :: any, extra :: term) ::
    {:ok, new_state :: any} |
    {:error, reason :: term} when old_vsn: term | {:down, term}

  @typedoc "The init parameters, received from the newly connected client"
  @type init_parameters :: %{
    required(:protocol) => String.t,
    required(:clean_session) => boolean,
    required(:client_id) => String.t,
    optional(:username) => String.t,
    optional(:password) => String.t,
    optional(:last_will) => %{
      topic: iodata,
      message: iodata,
      qos: :mqtt_packet.qos,
      retain: boolean
    }
  }

  @typedoc "The reason for rejecting a connection"
  @type init_stop_reason ::
    :identifier_rejected |
    :server_unavailable |
    :bad_username_or_password |
    :not_authorized |
    6..255

  @type action ::
    {:publish, topic :: String.t, message :: iodata} |
    {:publish, topic :: String.t, message :: iodata, %{optional(:qos) => :mqtt_packet.qos, optional(:retain) => boolean}} |
    {:reply, :gen_statem.from(), term()}

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour __MODULE__

      @doc false
      def handle_publish(_topic, _msg, _opts, state) do
        {:ok, state}
      end

      @doc false
      def handle_subscribe(_topic, _qos, state) do
        {:ok, :failed, state}
      end

      @doc false
      def handle_unsubscribe(_topic, state) do
        {:ok, state}
      end

      @doc false
      def handle_call(msg, from, state) do
        {:ok, state, {:reply, from, {:error, {:bad_call, msg}}}}
      end

      @doc false
      def handle_info(msg, state) do
        {:ok, state}
      end

      @doc false
      def handle_cast(msg, state) do
        {:ok, state}
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      @doc false
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      defoverridable [handle_publish: 4, handle_subscribe: 3, handle_unsubscribe: 2,
                      handle_call: 3, handle_info: 2, handle_cast: 2,
                      terminate: 2, code_change: 3]
    end
  end

  defdelegate enter_loop(module, args, transport), to: :mqtt_server

  defdelegate stop(pid), to: :mqtt_server

  defdelegate stop(pid, reason, timeout), to: :mqtt_server
end
