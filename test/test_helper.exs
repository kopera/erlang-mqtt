Code.require_file("support/test_client.exs", __DIR__)

ExUnit.configure exclude: [:external, :skip]
ExUnit.start()
