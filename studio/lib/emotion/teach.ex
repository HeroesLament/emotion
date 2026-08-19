defmodule EMotion.Teach do
  @moduledoc """
  Teaching: naming where the arm is, and what is on the end of it.

  The other half of `EMotion.Program`. A program refers to points by name, so
  something has to put the names there, and the only honest way to establish
  where a point is is to put the arm on it and say so. That is what every one
  of these does.

  Like `EMotion.Program`, this is a vocabulary over `EMotion.Link.call/3` with
  no state of its own.

  ## A pose is not a location until you say what it is measured from

  `teach_point/3` records the arm's current pose *in a frame*, so re-teaching
  that frame moves every point taught in it — which is how a fixture that has
  been knocked can be corrected in one operation rather than by re-teaching
  forty points.

  The fitted tool is recorded alongside, because a pose taught with one tool
  does not describe the same physical location with another. And the joint
  solution the arm is actually in is stored too, which is what lets a replay
  reach the pose on the configuration it was taught on rather than the mirror
  of it — the whole reason `move_joint` exists next to `move_linear`.

  ## Mastering is not here by accident

  `mastering/1` and `master_axis/3` sit with teaching because they answer the
  question underneath it: whether the numbers coming off the drives may be read
  as joint angles at all. A point taught on an unmastered arm records where the
  encoder happened to be, which is a number that means nothing tomorrow.
  """

  alias EMotion.Link

  # ── Points ────────────────────────────────────────────────────────────────

  @doc """
  Records where the arm is now, under a name.

  Re-teaching an existing name moves the point: a position that was taught
  slightly wrong and taught again is the same position, not a second one.

  `frame` defaults to the cell's base frame on the controller. Pass one to
  teach relative to a fixture.
  """
  @spec teach_point(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def teach_point(name, opts \\ []) do
    args =
      %{"name" => name}
      |> maybe_put("frame", Keyword.get(opts, :frame))
      |> maybe_put("mutable", Keyword.get(opts, :mutable))

    Link.call("cell.teach_point", args, opts)
  end

  @doc """
  Deletes a point.

  Refused if a program refers to it — the controller stores the reference as a
  foreign key precisely so that this refusal exists. A point that vanishes out
  from under a program turns an editing mistake into a motion one.
  """
  @spec forget_point(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def forget_point(name, opts \\ []), do: Link.call("cell.forget_point", %{"name" => name}, opts)

  @doc "Every taught point."
  @spec list_points(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_points(opts \\ []) do
    Link.call("cell.list_points", %{}, opts) |> field("points")
  end

  # ── Frames ────────────────────────────────────────────────────────────────

  @doc "Teaches a coordinate frame. See the controller's own description for the forms it takes."
  @spec teach_frame(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def teach_frame(name, extra \\ %{}, opts \\ []) do
    Link.call("cell.teach_frame", Map.put(extra, "name", name), opts)
  end

  @doc "Deletes a frame."
  @spec forget_frame(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def forget_frame(name, opts \\ []), do: Link.call("cell.forget_frame", %{"name" => name}, opts)

  @doc "Every taught frame."
  @spec list_frames(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_frames(opts \\ []) do
    Link.call("cell.list_frames", %{}, opts) |> field("frames")
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  @doc "Teaches a tool: the flange-to-TCP transform."
  @spec teach_tool(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def teach_tool(name, extra \\ %{}, opts \\ []) do
    Link.call("cell.teach_tool", Map.put(extra, "name", name), opts)
  end

  @doc "Every taught tool."
  @spec list_tools(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(opts \\ []) do
    Link.call("cell.list_tools", %{}, opts) |> field("tools")
  end

  @doc """
  Declares which tool is on the flange.

  Not a decoration: it changes where the TCP is, so it changes what every
  subsequent taught point means and where every cartesian move goes.
  """
  @spec fit_tool(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fit_tool(name, opts \\ []), do: Link.call("cell.fit_tool", %{"name" => name}, opts)

  @doc "Declares the flange bare."
  @spec release_tool(keyword()) :: {:ok, map()} | {:error, term()}
  def release_tool(opts \\ []), do: Link.call("cell.release_tool", %{}, opts)

  @doc "Which tool is fitted, or nil."
  @spec fitted_tool(keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fitted_tool(opts \\ []) do
    with {:ok, values} <- Link.read(["cell.tool"], opts), do: {:ok, values["cell.tool"]}
  end

  # ── Mastering ─────────────────────────────────────────────────────────────

  @doc """
  Each axis's mastering state: `unmastered`, `unreferenced` or `referenced`.

  Three states rather than a boolean, because they are three different missing
  facts. `unmastered` means nobody ever declared a zero. `unreferenced` means
  one was declared and the drive is no longer confident it survived — it was
  backdriven while off, or the record and the encoder disagree by more than the
  tolerance. Only `referenced` means a joint angle may be believed.
  """
  @spec mastering(keyword()) :: {:ok, [map()]} | {:error, term()}
  def mastering(opts \\ []) do
    Link.call("cell.mastering", %{}, opts) |> field("axes")
  end

  @doc """
  Whether every axis is referenced, in one read.

  What to check before offering to run anything.
  """
  @spec referenced?(keyword()) :: {:ok, boolean()} | {:error, term()}
  def referenced?(opts \\ []) do
    with {:ok, values} <- Link.read(["cell.referenced"], opts) do
      {:ok, values["cell.referenced"] == true}
    end
  end

  @doc """
  Declares that an axis is physically at `at` radians right now.

  The drive owns the zero, because the encoder is on the drive. This asks it to
  record one; the controller shadows what it reports and notices when it
  changes. Refused while the axis has output enabled — an axis that could be
  moving cannot truthfully be said to be anywhere.
  """
  @spec master_axis(String.t(), float() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def master_axis(axis, at \\ nil, opts \\ []) do
    Link.call("cell.master_axis", maybe_put(%{"axis" => to_string(axis)}, "at", at), opts)
  end

  # ==========================================================================

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Strict on purpose. `with {:ok, %{"key" => v}} <- call()` looks right and is
  # not: a result that does not match falls through `with` unchanged, so the
  # caller gets {:ok, something_else} and discovers it several frames later.
  # This says so at the boundary instead.
  defp field({:ok, %{} = result}, key) do
    case result do
      %{^key => value} -> {:ok, value}
      _ -> {:error, {:unexpected_result, key, result}}
    end
  end

  defp field({:error, _reason} = error, _key), do: error

end
