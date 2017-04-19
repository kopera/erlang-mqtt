defmodule MQTT.Client.IntegrationTest do

  @moduledoc false

  use ExUnit.Case
  alias MQTT.TestClient

  @tag :external
  test "Client should handle publish and subscribe" do
    Process.register self(), :test_client

    {:ok, pid} = TestClient.start_link(
      %{:transport => {:tcp,
          %{:host => "localhost"}},
      })
    assert_receive {:connected, false}

    topic = "/my/data/topic"

    TestClient.subscribe(pid, topic)
    assert_receive {:subscribed, ^topic}

    TestClient.publish(pid, topic, "Hello")
    assert_receive {:publish, ^topic, "Hello"}

  end

  @tag :external
  test "Client should support Last Will and Testament" do
    Process.register self(), :test_client

    lwt_topic = "/last/will"
    {:ok, pid1} = TestClient.start_link(%{
        last_will: %{
          topic: lwt_topic,
          message: "Goodbye cruel World!",
          qos: 0,
          retain: false
        }
    })
    assert_receive {:connected, false}

    {:ok, pid2} = TestClient.start_link(%{})
    assert_receive {:connected, false}

    TestClient.subscribe(pid2, lwt_topic)
    assert_receive {:subscribed, ^lwt_topic}

    :gen_fsm.stop(pid1)

    assert_receive {:publish, ^lwt_topic, "Goodbye cruel World!"}

  end

end
