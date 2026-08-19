defmodule EMotion.Schema.Compiler do
  @moduledoc """
  Compiles and validates an E-Motion Schema Model.

  Responsibilities:
  - normalize path fields on every node (derived from tree position)
  - validate child IDs are present and non-empty
  - validate sibling IDs are unique within each object
  - validate property/method/event types are known primitives or resolvable refs
  - returns {:ok, compiled_model} or {:error, [reasons]}
  """

  alias EMotion.Schema.{Model, Object, Property, Method, Event, Type}

  @spec compile(Model.t()) :: {:ok, Model.t()} | {:error, [String.t()]}
  def compile(%Model{} = model) do
    {root, path_errors} = normalize_paths(model.root, [model.root.name])
    type_errors         = validate_types(root, model.types)
    id_errors           = validate_ids(root)

    errors = path_errors ++ type_errors ++ id_errors

    if errors == [] do
      {:ok, %{model | root: root}}
    else
      {:error, errors}
    end
  end

  # ── Path normalization ───────────────────────────────────────────────────────

  defp normalize_paths(%Object{} = obj, path) do
    {children, errors} =
      Enum.map_reduce(obj.children, [], fn child, acc ->
        child_path = path ++ [child_name(child)]
        {normalized, errs} = normalize_paths(child, child_path)
        {normalized, acc ++ errs}
      end)

    {%{obj | path: path, children: children}, errors}
  end

  defp normalize_paths(%Property{} = p, path), do: {%{p | path: path}, []}
  defp normalize_paths(%Method{}   = m, path), do: {%{m | path: path}, []}
  defp normalize_paths(%Event{}    = e, path), do: {%{e | path: path}, []}

  defp child_name(%{name: name}), do: name

  # ── ID validation ─────────────────────────────────────────────────────────

  defp validate_ids(%Object{} = obj) do
    errors = if blank?(obj.id), do: ["Object missing id at path #{inspect(obj.path)}"], else: []

    sibling_ids  = Enum.map(obj.children, & &1.id)
    dup_errors   =
      sibling_ids
      |> Enum.frequencies()
      |> Enum.flat_map(fn
        {id, n} when n > 1 -> ["Duplicate child id #{inspect(id)} in #{inspect(obj.id)}"]
        _                   -> []
      end)

    child_errors = Enum.flat_map(obj.children, &validate_ids/1)
    errors ++ dup_errors ++ child_errors
  end

  defp validate_ids(%Property{id: id, path: path}) do
    if blank?(id), do: ["Property missing id at path #{inspect(path)}"], else: []
  end

  defp validate_ids(%Method{id: id, path: path}) do
    if blank?(id), do: ["Method missing id at path #{inspect(path)}"], else: []
  end

  defp validate_ids(%Event{id: id, path: path}) do
    if blank?(id), do: ["Event missing id at path #{inspect(path)}"], else: []
  end

  # ── Type validation ───────────────────────────────────────────────────────

  defp validate_types(%Object{} = obj, types) do
    Enum.flat_map(obj.children, &validate_types(&1, types))
  end

  defp validate_types(%Property{type: type, path: path}, types) do
    validate_type(type, path, types)
  end

  defp validate_types(%Method{input_args: ins, output_args: outs, path: path}, types) do
    arg_errors    = Enum.flat_map(ins,  fn a -> validate_type(a.type, path ++ [a.name], types) end)
    result_errors = Enum.flat_map(outs, fn r -> validate_type(r.type, path ++ [r.name], types) end)
    arg_errors ++ result_errors
  end

  defp validate_types(%Event{payload_type: type, path: path}, types) do
    validate_type(type, path, types)
  end

  defp validate_type(type, path, types) do
    case type do
      t when is_atom(t) ->
        if Type.primitive?(t) do
          []
        else
          ["Unknown primitive type #{inspect(t)} at #{inspect(path)}"]
        end

      {:ref, ref_id} ->
        if Map.has_key?(types, ref_id) do
          []
        else
          ["Unresolved type ref #{inspect(ref_id)} at #{inspect(path)}"]
        end

      {:enum, %EMotion.Schema.Enum{}} -> []
      {:struct, %EMotion.Schema.StructType{}} -> []

      {:array, inner} ->
        validate_type(inner, path ++ ["[]"], types)

      other ->
        ["Unknown type shape #{inspect(other)} at #{inspect(path)}"]
    end
  end

  defp blank?(nil), do: true
  defp blank?(""),  do: true
  defp blank?(_),   do: false
end
