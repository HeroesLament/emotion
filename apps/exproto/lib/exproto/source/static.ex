defmodule ExProto.Source.Static do
  @moduledoc """
  A value source backed by a plain map. For tests, and for bringing the
  protocol up before any drives exist.

  Holds values in an Agent so writes stick across calls without the caller
  threading state, which is what a real source will look like from the
  dispatcher's side anyway — the difference between this and a registry of
  running drives is entirely on the far side of the behaviour.

  ## Fault injection

  `:clamp` and `:reject` exist because the interesting protocol behaviour is at
  the edges. A source that always succeeds cannot demonstrate that a clamped
  write reports what actually happened rather than what was asked for, and
  cannot exercise the refusal path at all — which is the same argument as
  running a momentum observer against a deliberately wrong plant.
  """

  @behaviour ExProto.Source

  use Agent

  @doc """
  Starts a source.

    * `:values` — initial `node_id => value` map
    * `:clamp` — `node_id => {min, max}`, values outside are clamped and the
      clamped value reported back
    * `:reject` — node ids whose writes are refused, as an unenabled drive would
  """
  def start_link(opts \\ []) do
    state = %{
      values: Keyword.get(opts, :values, %{}),
      clamp: Keyword.get(opts, :clamp, %{}),
      reject: MapSet.new(Keyword.get(opts, :reject, []))
    }

    Agent.start_link(fn -> state end)
  end

  @impl ExProto.Source
  def read(node_id, pid) do
    Agent.get(pid, fn state ->
      case Map.fetch(state.values, node_id) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :unknown_node}
      end
    end)
  end

  @impl ExProto.Source
  def write(node_id, value, pid) do
    Agent.get_and_update(pid, fn state ->
      cond do
        MapSet.member?(state.reject, node_id) ->
          {{:error, :rejected}, state}

        not Map.has_key?(state.values, node_id) ->
          {{:error, :unknown_node}, state}

        true ->
          applied = clamp(value, Map.get(state.clamp, node_id))
          {{:ok, applied}, put_in(state.values[node_id], applied)}
      end
    end)
  end

  @doc "Sets a value directly, as a drive moving would."
  def put(pid, node_id, value) do
    Agent.update(pid, &put_in(&1.values[node_id], value))
  end

  defp clamp(value, nil), do: value

  defp clamp(value, {min, max}) when is_number(value) do
    value |> max(min) |> min(max)
  end

  defp clamp(value, _bounds), do: value
end
