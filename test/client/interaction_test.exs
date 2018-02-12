defmodule MQTT.Client.IntegrationTest do

  @moduledoc false

  use ExUnit.Case
  alias MQTT.Client

  @tag :external
  test "Client should handle publish and subscribe" do
    {:ok, connection} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}}
    })

    topic = "/my/data/topic"

    {:ok, [{^topic, 0}]} = Client.subscribe(connection, topic)
    :ok = Client.publish(connection, topic, "Hello")
  end

  @tag :external
  test "Client should support Last Will and Testament" do
    lwt_topic = "/last/will"
    lwt_message = "Goodbye cruel World!"

    {:ok, connection1} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}},
      last_will: %{
        topic: lwt_topic,
        message: lwt_message,
        qos: 0,
        retain: false
      }
    })

    {:ok, connection2} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}}
    })

    {ok, [{lwt_topic, _}]} = Client.subscribe(connection2, lwt_topic)
    :gen_fsm.stop(connection1)

    assert_receive {:mqtt_client, ^connection2, {:publish, ^lwt_topic, ^lwt_message}}

  end

end
