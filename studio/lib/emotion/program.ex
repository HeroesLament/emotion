defmodule EMotion.Program do
  @moduledoc """
  Programs, as the studio sees them.

  A thin, named vocabulary over `EMotion.Link.call/3`. There is no state here
  and no process: a program lives on the controller, and a studio that kept its
  own copy would be a second source of truth for the thing the arm is about to
  do. Everything here is a question asked over the wire and answered now.

  ## Editing is statement at a time, and that is not a limitation

  `protocol/PROGRAMS.md` records that bulk transfer — program source, logs,
  motion traces — stays on plain HTTP so it does not compete with live
  telemetry. So the wire carries what an editor actually does: append one,
  replace one, remove one, move one. A "save" button that uploads a whole body
  is a worse fit for a pendant anyway, because the thing being edited is
  usually running or about to be.

  ## Validate and the edit calls fail differently, on purpose

  `validate/2` is a read. It returns `%{"ok" => false, "socket" => "point",
  "reason" => "no such point: weld_start"}` — it can name the argument that is
  wrong, because naming things is all it does.

  The edit calls command, and a command refuses with a fixed error vocabulary
  that cannot carry a socket name. So an editor should validate as somebody
  types and let the refusal be the backstop, rather than the other way round.

  ## Mode

  `start/2` is refused unless the mode selector is in auto, and jogging is
  refused unless it is in manual. That is not an inconsistency to work around:
  teaching happens with a person at the arm and running happens with one
  further away, and the selector is how the machine is told which. On a bench
  controller it is turned with `ExProto.Mode.select/1`, locally — deliberately
  not over this protocol, because a keyswitch that can be turned from another
  building is not a keyswitch.
  """

  alias EMotion.Link

  @typedoc """
  A statement argument on the wire.

  References travel as names — `%{"name" => "point", "value" => "weld_start"}` —
  because a name is what a person taught. The controller stores a foreign key,
  which is what later refuses the point's deletion.
  """
  @type arg :: %{required(String.t()) => term()}

  # ── The library ───────────────────────────────────────────────────────────

  @doc "Every stored program."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    Link.call("program.list", %{}, opts) |> field("programs")
  end

  @doc """
  A program's statements, in order, with their arguments resolved.

  The readable form: what each statement is and what it references, rather than
  the foreign keys it stores.
  """
  @spec show(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def show(name, opts \\ []) do
    Link.call("program.show", %{"name" => name}, opts) |> field("statements")
  end

  @doc "Creates an empty program."
  @spec create(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create(name, opts \\ []), do: Link.call("program.create", %{"name" => name}, opts)

  @doc """
  Deletes a program.

  Refused while it is the program that is running, which is the same rule the
  edit calls follow: a program nobody is running is a program anyone may change.
  """
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(name, opts \\ []), do: Link.call("program.delete", %{"name" => name}, opts)

  # ── Editing ───────────────────────────────────────────────────────────────

  @doc """
  Adds a statement to the end, returning the sequence number it landed at.

      append("pick", "move_joint", [%{"name" => "point", "value" => "home"}])
      #=> {:ok, 0}
  """
  @spec append(String.t(), String.t(), [arg()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append(program, kind, args \\ [], opts \\ []) do
    Link.call("program.append", %{"program" => program, "kind" => kind, "args" => args}, opts)
    |> field("seq")
  end

  @doc "Replaces the statement at `seq`, kind and all."
  @spec replace(String.t(), non_neg_integer(), String.t(), [arg()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def replace(program, seq, kind, args \\ [], opts \\ []) do
    Link.call(
      "program.replace",
      %{"program" => program, "seq" => seq, "kind" => kind, "args" => args},
      opts
    )
  end

  @doc "Removes the statement at `seq`. Everything after it shifts up."
  @spec remove(String.t(), non_neg_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove(program, seq, opts \\ []) do
    Link.call("program.remove", %{"program" => program, "seq" => seq}, opts)
  end

  @doc "Moves the statement at `seq` to position `to`."
  @spec move(String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def move(program, seq, to, opts \\ []) do
    Link.call("program.move", %{"program" => program, "seq" => seq, "to" => to}, opts)
  end

  # ── What can be written ───────────────────────────────────────────────────

  @doc """
  Every statement kind this controller knows, with its parameters.

  The palette comes from the controller rather than from a list here, so a
  build that loads an extension offers it without the studio being rebuilt —
  and a studio that predates a kind draws it from its declared parameters
  instead of not drawing it at all.
  """
  @spec kinds(keyword()) :: {:ok, [map()]} | {:error, term()}
  def kinds(opts \\ []) do
    Link.call("program.kinds", %{}, opts) |> field("kinds")
  end

  @doc """
  Whether a statement would be accepted, and if not, which argument is wrong.

      validate("move_joint", [%{"name" => "point", "value" => "nowhere"}])
      #=> {:ok, %{"ok" => false, "socket" => "point", "reason" => "..."}}

  `{:ok, _}` means the question was answered, not that the statement is valid.
  Read `"ok"`.
  """
  @spec validate(String.t(), [arg()], keyword()) :: {:ok, map()} | {:error, term()}
  def validate(kind, args \\ [], opts \\ []) do
    Link.call("program.validate", %{"kind" => kind, "args" => args}, opts)
  end

  # ── Running ───────────────────────────────────────────────────────────────

  @doc """
  Runs a program from its first statement.

  Returns as soon as the run is accepted — the arm has not moved yet. Watch
  `status/1`. Refused outside auto, refused while another program runs, and
  refused if the program uses a kind this build does not know.
  """
  @spec start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(name, opts \\ []), do: Link.call("program.start", %{"name" => name}, opts)

  @doc "Pauses at the end of the statement in flight. The arm finishes its move."
  @spec hold(keyword()) :: {:ok, map()} | {:error, term()}
  def hold(opts \\ []), do: Link.call("program.hold", %{}, opts)

  @doc "Continues a held program."
  @spec resume(keyword()) :: {:ok, map()} | {:error, term()}
  def resume(opts \\ []), do: Link.call("program.resume", %{}, opts)

  @doc """
  Runs one statement and holds again.

  A step does not stop the arm: the statement that was issued gets to finish.
  A step that commanded a move and then cancelled it would be a button that
  does nothing, slowly.
  """
  @spec step(keyword()) :: {:ok, map()} | {:error, term()}
  def step(opts \\ []), do: Link.call("program.step", %{}, opts)

  @doc "Ends the run and releases the arm."
  @spec stop(keyword()) :: {:ok, map()} | {:error, term()}
  def stop(opts \\ []), do: Link.call("program.stop", %{}, opts)

  @doc """
  What the run is doing, in one round trip.

      %{name: "pick", state: "running", statement: 2, statements: 5,
        kind: "move_joint", reason: ""}

  Six properties read together rather than six reads, because a name from one
  moment and a statement index from the next describe a program that was never
  in that state.
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []) do
    ids = ~w(program.name program.state program.statement program.statements
             program.kind program.reason)

    with {:ok, values} <- EMotion.Link.read(ids, opts) do
      {:ok,
       %{
         name: values["program.name"],
         state: values["program.state"],
         statement: values["program.statement"],
         statements: values["program.statements"],
         kind: values["program.kind"],
         reason: values["program.reason"]
       }}
    end
  end

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
