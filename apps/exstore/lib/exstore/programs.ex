defmodule ExStore.Programs do
  @moduledoc """
  Stored programs and their bodies.

  The body is a list of statements ordered by `seq`, and this module owns the
  one invariant that ordering brings with it: `seq` is dense and starts at zero
  after any edit. Sparse or duplicated sequence numbers are the sort of thing
  that works until somebody inserts a line at the top.

  What it deliberately does not own is what a statement *means*. Kinds are
  validated against a registry that lives above this app, because extensions
  contribute kinds and extensions are compiled code this layer cannot see.
  """

  import Ecto.Query

  alias ExStore.Program.{Program, Statement, StatementRef}
  alias ExStore.Repo

  def list, do: Repo.all(from(p in Program, order_by: p.name))

  def get(id), do: Repo.get(Program, id)

  def by_name(name) when is_binary(name), do: Repo.get_by(Program, name: name)

  def create(attrs) do
    %Program{} |> Program.changeset(attrs) |> Repo.insert()
  end

  def rename(%Program{} = program, attrs) do
    program |> Program.changeset(attrs) |> Repo.update()
  end

  def delete(%Program{} = program), do: Repo.delete(program)

  @doc """
  The body, in order, with references loaded.

  One query per program rather than one per statement: a body is read every time
  a run starts, and a hundred-statement program should not be a hundred round
  trips at the moment somebody presses go.
  """
  def body(%Program{} = program) do
    Repo.all(
      from(s in Statement,
        where: s.program_id == ^program.id,
        order_by: s.seq,
        preload: [:refs]
      )
    )
  end

  @doc """
  Appends a statement.

  `refs` is `%{"point" => {:point, id}}` — the socket name to what fills it.
  Literals go in `args`.
  """
  def append(%Program{} = program, kind, args \\ %{}, refs \\ %{}) do
    Repo.transaction(fn ->
      seq = Repo.one(from(s in Statement, where: s.program_id == ^program.id, select: count()))

      statement =
        %Statement{}
        |> Statement.changeset(%{program_id: program.id, seq: seq, kind: kind, args: args})
        |> insert_or_rollback()

      put_refs(statement, refs)
      %{statement | refs: Repo.all(from(r in StatementRef, where: r.statement_id == ^statement.id))}
    end)
  end

  @doc "Replaces a statement's kind, literals and references, keeping its place."
  def replace(%Statement{} = statement, kind, args \\ %{}, refs \\ %{}) do
    Repo.transaction(fn ->
      updated =
        statement
        |> Statement.changeset(%{kind: kind, args: args})
        |> update_or_rollback()

      Repo.delete_all(from(r in StatementRef, where: r.statement_id == ^statement.id))
      put_refs(updated, refs)
      updated
    end)
  end

  @doc """
  Removes a statement and closes the gap.

  Renumbering is why this is a function rather than a delete: `seq` is dense, and
  the identity a jump would use is the row's `id`, which does not move.
  """
  def remove(%Statement{} = statement) do
    Repo.transaction(fn ->
      Repo.delete!(statement)
      renumber(statement.program_id)
      :ok
    end)
  end

  @doc "Moves a statement to a new position, sliding the rest along."
  def move(%Statement{} = statement, to) when is_integer(to) and to >= 0 do
    Repo.transaction(fn ->
      others =
        from(s in Statement,
          where: s.program_id == ^statement.program_id and s.id != ^statement.id,
          order_by: s.seq
        )
        |> Repo.all()

      {before, rest} = Enum.split(others, to)

      (before ++ [statement] ++ rest)
      |> Enum.with_index()
      # Out of the way first, then into place. SQLite enforces the (program, seq)
      # unique index per statement rather than at commit, so writing the new
      # order directly collides with the old one halfway through.
      |> tap(fn ordered ->
        for {s, index} <- ordered do
          Repo.update_all(from(x in Statement, where: x.id == ^s.id), set: [seq: -index - 1])
        end
      end)
      |> Enum.each(fn {s, index} ->
        Repo.update_all(from(x in Statement, where: x.id == ^s.id), set: [seq: index])
      end)

      :ok
    end)
  end

  @doc "Every statement that references this point. What refuses its deletion."
  def statements_referencing(:point, id) do
    Repo.all(from(r in StatementRef, where: r.point_id == ^id, preload: [:statement]))
  end

  defp renumber(program_id) do
    from(s in Statement, where: s.program_id == ^program_id, order_by: s.seq)
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.each(fn {statement, index} ->
      if statement.seq != index do
        Repo.update_all(from(x in Statement, where: x.id == ^statement.id), set: [seq: index])
      end
    end)
  end

  defp put_refs(statement, refs) do
    for {arg_name, {kind, id}} <- refs do
      attrs =
        Map.new([
          {:statement_id, statement.id},
          {:arg_name, to_string(arg_name)},
          {:"#{kind}_id", id}
        ])

      %StatementRef{}
      |> StatementRef.changeset(attrs)
      |> insert_or_rollback()
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, row} -> row
      {:error, failed} -> Repo.rollback(failed)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, row} -> row
      {:error, failed} -> Repo.rollback(failed)
    end
  end
end
