defmodule MQTT.Client.IntegrationTest do

  @moduledoc false

  use ExUnit.Case
  alias MQTT.Client

  @tag :external
  test "Client should handle publish and subscribe" do
    {:ok, connection, false} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}}
    })

    topic = "/my/data/topic"
    message = "Hello"

    {:ok, [{^topic, 0}]} = Client.subscribe(connection, [{topic, 0}])
    :ok = Client.publish(connection, topic, message)

    assert_receive {:mqtt_client, ^connection, {:publish, ^topic, ^message, _}}

    :ok = Client.disconnect(connection)
  end

  @tag :external
  test "Client should support Last Will and Testament" do
    lwt_topic = "/last/will"
    lwt_message = "Goodbye cruel World!"

    {:ok, connection1, false} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}},
      last_will: %{
        topic: lwt_topic,
        message: lwt_message,
        qos: 0,
        retain: false
      }
    })

    {:ok, connection2, false} = Client.connect(%{
      transport: {:tcp, %{host: "localhost"}}
    })

    {:ok, [{lwt_topic, _}]} = Client.subscribe(connection2, [lwt_topic])
    :gen_statem.stop(connection1)

    assert_receive {:mqtt_client, ^connection2, {:publish, ^lwt_topic, ^lwt_message, _}}

    :ok = Client.disconnect(connection1)
    :ok = Client.disconnect(connection2)
  end

end
