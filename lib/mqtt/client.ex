defmodule MQTT.Client do
  @moduledoc """
  A behaviour module for implementing an MQTT client.
  """

  @callback init(args :: any()) ::
      {:ok, state :: any()} |
      {:stop, reason :: term()}
      :ignore

  @callback handle_connect(session_present :: boolean(), state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback handle_connect_error(reason :: term(), state :: any()) ::
      {:reconnect, {:backoff, min :: non_neg_integer(), max :: pos_integer()}, state :: any()} |
      {:stop, reason :: term()}

  @callback handle_disconnect(reason :: term(), state :: any()) ::
      {:reconnect, {:backoff, min :: non_neg_integer(), max :: pos_integer()}, state :: any()} |
      {:stop, reason :: term()}

  @callback handle_publish(topic :: binary(), message :: binary(), state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback handle_subscribe_result(topic :: binary(), :mqtt_packet.qos() | :failed, state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback handle_call(call :: any(), from :: :gen_statem.from(), state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback handle_cast(cast :: any(), state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback handle_info(info :: any(), state :: any()) ::
      {:ok, state :: any()} |
      {:ok, state :: any(), action() | [action()]} |
      {:stop, reason :: term()}

  @callback terminate(:normal | :shutdown | {:shutdown, term()} | term(), state :: any()) ::
      any()

  @callback code_change(oldVsn :: term() | {:down, term()}, oldState :: any(), extra :: term()) ::
      {:ok, new_state :: any()} |
      term()


  @type action ::
      {:publish, topic :: String.t, message :: iodata} |
      {:publish, topic :: String.t, message :: iodata, %{optional(:qos) => :mqtt_packet.qos, optional(:retain) => boolean}} |
      {:reply, :gen_statem.from(), term()}

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behaviour :mqtt_client

      @doc false
      def init(_) do
        {:ok, %{}}
      end

      @doc false
      def handle_connect(_session_present, state) do
          {:ok, state}
      end

      @doc false
      def handle_connect_error(reason, _state) do
          {:stop, reason}
      end

      @doc false
      def handle_disconnect(reason, _state) do
          {:stop, reason}
      end

      @doc false
      def handle_publish(_topic, _message, state) do
          {:ok, state}
      end

      @doc false
      def handle_subscribe_result(_topic, _status, state) do
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
        {:ok, state, msg}
      end

      @doc false
      def terminate(_reason, _state) do
        :ok
      end

      @doc false
      def code_change(_old, state, _extra) do
        {:ok, state}
      end

      defoverridable [init: 1, handle_connect: 2, handle_connect_error: 2,
                      handle_disconnect: 2, handle_publish: 3,
                      handle_subscribe_result: 3, handle_call: 3,
                      handle_info: 2, handle_cast: 2,
                      terminate: 2, code_change: 3]

    end
  end

  @spec start_link(module(), any(), map()) :: {:ok, pid}
  def start_link(module, args, options) do
    :mqtt_client.start_link(module, args, options)
  end

  @type start_options() :: %{
      :transport => {:tcp, map()} | {:ssl, map()},
      :keep_alive => non_neg_integer(),
      :protocol => iodata(),
      :username => iodata(),
      :password => iodata(),
      :client_id => iodata(),
      :clean_session => boolean(),
      :last_will => %{
          :topic => iodata(),
          :message => iodata(),
          :qos => :mqtt_packet.qos(),
          :retain => boolean()
      }
  }

end
