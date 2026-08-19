defmodule EMotion.Canonical do
  @moduledoc """
  Rendering rules shared by every artifact that carries a hash.

  Small, and worth its own module rather than being duplicated: a program file
  and an installation file are hashed the same way, and two copies of "how a
  float is written" would eventually disagree — at which point the same machine
  produces two fingerprints and nobody can tell which is stale.
  """

  @doc """
  A number, written the same way every time.

  Fixed at nine places rather than left to the shortest representation, because
  the shortest representation of a double is not stable across a JSON round
  trip, and a fingerprint that changes when a file is opened and saved is not a
  fingerprint. Nine places is past anything this arm's encoders resolve and well
  inside a double.
  """
  @spec number(term()) :: String.t()
  def number(nil), do: "0.000000000"
  def number(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 9)
  def number(other), do: to_string(other)

  @doc "The identity of a canonical rendering."
  @spec hash(String.t()) :: String.t()
  def hash(text) when is_binary(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  @doc "The first twelve characters of a hash, for showing a person."
  @spec short(String.t()) :: String.t()
  def short(hash) when is_binary(hash), do: binary_part(hash, 0, 12)
end
