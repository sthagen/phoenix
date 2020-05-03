Code.require_file "../../../installer/test/mix_helper.exs", __DIR__

defmodule Mix.Tasks.Phx.Gen.SecretTest do
  use ExUnit.Case
  import Mix.Tasks.Phx.Gen.Secret

  test "generates a secret" do
    run []
    assert_receive {:mix_shell, :info, [secret]} when byte_size(secret) == 64
    assert String.printable?(secret)
  end

  test "generates a secret with custom length" do
    run ["32"]
    assert_receive {:mix_shell, :info, [secret]} when byte_size(secret) == 32
    assert String.printable?(secret)
  end

  test "raises on invalid args" do
    message = "mix phx.gen.secret expects a length as integer or no argument at all"
    assert_raise Mix.Error, message, fn -> run ["bad"] end
    assert_raise Mix.Error, message, fn -> run ["32bad"] end
    assert_raise Mix.Error, message, fn -> run ["32", "bad"] end
  end

  test "raises when length is too short" do
    message = "The secret should be at least 32 characters long"
    assert_raise Mix.Error, message, fn -> run ["0"] end
    assert_raise Mix.Error, message, fn -> run ["31"] end
  end
end
