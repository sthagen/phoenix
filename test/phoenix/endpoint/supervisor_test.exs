defmodule Phoenix.Endpoint.SupervisorTest do
  use ExUnit.Case, async: true
  alias Phoenix.Endpoint.Supervisor

  setup do
    Application.put_env(:phoenix, SupervisorApp.Endpoint, custom: true)
    System.put_env("PHOENIX_PORT", "8080")
    System.put_env("PHOENIX_HOST", "example.org")
    :ok
  end

  test "loads router configuration" do
    config = Supervisor.config(:phoenix, SupervisorApp.Endpoint)
    assert config[:otp_app] == :phoenix
    assert config[:custom] == true
    assert config[:render_errors] == [view: SupervisorApp.ErrorView, accepts: ~w(html), layout: false]
  end

  defmodule HTTPSEndpoint do
    def path(path), do: path
    def config(:http), do: false
    def config(:https), do: [port: 443]
    def config(:url), do: [host: "example.com"]
    def config(:otp_app), do: :phoenix
  end

  defmodule HTTPEndpoint do
    def path(path), do: path
    def config(:https), do: false
    def config(:http), do: [port: 80]
    def config(:url), do: [host: "example.com"]
    def config(:otp_app), do: :phoenix
  end

  defmodule HTTPEnvVarEndpoint do
    def config(:https), do: false
    def config(:http), do: [port: {:system,"PHOENIX_PORT"}]
    def config(:url), do: [host: {:system,"PHOENIX_HOST"}]
    def config(:otp_app), do: :phoenix
  end

  defmodule URLEndpoint do
    def config(:https), do: false
    def config(:http), do: false
    def config(:url), do: [host: "example.com", port: 678, scheme: "random"]
    def config(:static_url), do: nil
  end

  defmodule StaticURLEndpoint do
    def config(:https), do: false
    def config(:http), do: false
    def config(:static_url), do: [host: "static.example.com"]
  end

  defmodule ForceSslEndpoint do
    def init(:supervisor, config), do: {:ok, config}
    def __compile_config__(), do: [force_ssl: [rewrite_on: [:x_forwarded_proto]]]
  end

  test "generates the static url based on the static host configuration" do
    static_host = {:cache, "http://static.example.com"}
    assert Supervisor.static_url(StaticURLEndpoint) == static_host
  end

  test "static url fallbacks to url when there is no configuration for static_url" do
    assert Supervisor.static_url(URLEndpoint) == {:cache, "random://example.com:678"}
  end

  test "generates url" do
    assert Supervisor.url(URLEndpoint) == {:cache, "random://example.com:678"}
    assert Supervisor.url(HTTPEndpoint) == {:cache, "http://example.com"}
    assert Supervisor.url(HTTPSEndpoint) == {:cache, "https://example.com"}
    assert Supervisor.url(HTTPEnvVarEndpoint) == {:cache, "http://example.org:8080"}
  end

  test "static_path/2 returns file's path with lookup cache" do
    assert {:nocache, {"/phoenix.png", nil}} =
             Supervisor.static_lookup(HTTPEndpoint, "/phoenix.png")
    assert {:nocache, {"/images/unknown.png", nil}} =
             Supervisor.static_lookup(HTTPEndpoint, "/images/unknown.png")
  end

  test "compile_config_keys/0 returns config keys we want to store for runtime checks" do
    assert Supervisor.compile_config_keys() == [:force_ssl]
  end

  @tag :capture_log
  test "init/1 fails when force_ssl check fails" do
    Application.put_env(:phoenix, ForceSslEndpoint, force_ssl: [hsts: true])

    assert_raise ArgumentError,
                 "expected these options to be unchanged from compile time: [:force_ssl]",
                 fn -> Supervisor.init({:phoenix, ForceSslEndpoint, []}) end
  end
end
