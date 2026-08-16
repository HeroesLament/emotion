defmodule ExStore.Geometry.Pose do
  @moduledoc """
  The six numbers, and the validation both tables share.

  A frame and a tool are the same shape and mean different things, which is why
  they are two tables and one changeset helper rather than the reverse.
  """

  import Ecto.Changeset

  @fields [:x, :y, :z, :rx, :ry, :rz]

  @doc "The six pose fields, in the order everything else in the suite uses."
  def fields, do: @fields

  @doc """
  Casts and validates the six numbers.

  Refuses a non-finite value. `:infinity` reaching the Jacobian produces a NaN
  joint command, and a NaN compares false against every limit in
  `CARTESIAN.md` — so it passes all of them.
  """
  def cast_pose(changeset, attrs) do
    changeset
    |> cast(attrs, @fields)
    |> validate_finite()
  end

  @doc """
  A name a person types on a pendant and a program stores by reference.

  Lowercase, because case-sensitive names produce two frames that print the
  same and are not the same, and that is a fault nobody finds by reading.
  """
  def cast_name(changeset, attrs, reserved) do
    changeset
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 32)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message: "must be lowercase, start with a letter, and contain only letters, digits and _"
    )
    |> validate_exclusion(:name, reserved,
      message: "is reserved: the controller already means something by it"
    )
  end

  defp validate_finite(changeset) do
    Enum.reduce(@fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        nil -> acc
        value when is_float(value) -> if finite?(value), do: acc, else: add_error(acc, field, "must be a finite number")
        _other -> acc
      end
    end)
  end

  defp finite?(value), do: value == value and value not in [:infinity, :neg_infinity] and abs(value) < 1.0e12
end
