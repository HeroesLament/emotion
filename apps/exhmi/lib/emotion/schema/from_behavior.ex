defmodule EMotion.Schema.FromBehavior do
  @moduledoc """
  Converts an EMotion.Behavior.Definition into schema fragments suitable for
  merging into the ExMo Information Model.

  Each behavior contributes two fragments:

  1. Catalog fragment — under Behaviors/Catalog/<Name>
     A static, always-present description of the callable capability.
     Contains: Supported, Description properties, and Invoke method.

  2. Runtime fragment — properties for Behaviors/Runtime/ActiveBehavior
     The live fields exposed while this behavior is executing.
     These are merged into the generic ActiveBehavior object, not duplicated
     per behavior — one runtime view is active at a time.

  Usage:

      definition = EMotion.Behaviors.K1C.RemovePreviousPrint.definition()
      catalog    = EMotion.Schema.FromBehavior.catalog_object(definition)
      runtime    = EMotion.Schema.FromBehavior.runtime_properties(definition)
  """

  alias EMotion.Behavior.Definition
  alias EMotion.Schema.{Object, Property, Method}

  @doc """
  Returns an Object node for the behavior's catalog entry.

  Placed under Behaviors/Catalog/<behavior name>.
  Contains:
  - Supported: bool property (statically true)
  - Description: string property
  - Invoke: the callable method
  """
  @spec catalog_object(Definition.t()) :: Object.t()
  def catalog_object(%Definition{} = defn) do
    %Object{
      id:          "#{defn.id}.catalog",
      name:        defn.name,
      description: defn.description,
      children: [
        %Property{
          id:          "#{defn.id}.supported",
          name:        "Supported",
          description: "Whether this behavior is available on the current controller",
          type:        :boolean,
          readable:    true,
          writable:    false,
          observable:  false,
          default:     true
        },
        %Property{
          id:          "#{defn.id}.description",
          name:        "Description",
          description: "Human-readable description of this behavior",
          type:        :string,
          readable:    true,
          writable:    false,
          observable:  false,
          default:     defn.description
        },
        invoke_method(defn)
      ]
    }
  end

  @doc """
  Returns a list of Property nodes representing the generic ActiveBehavior
  runtime view for this behavior.

  These are placed under Behaviors/Runtime/ActiveBehavior.
  The ActiveBehavior object is shared across all behaviors — these fields
  are populated/updated when this behavior is the active one.

  Always includes the standard fields (Id, Name, JobId) plus the behavior's
  own declared runtime_fields.
  """
  @spec runtime_properties(Definition.t()) :: [Property.t()]
  def runtime_properties(%Definition{} = defn) do
    standard_fields() ++ behavior_runtime_fields(defn)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp invoke_method(%Definition{} = defn) do
    %Method{
      id:          "#{defn.id}.invoke",
      name:        "Invoke",
      description: "Invoke the #{defn.name} behavior",
      input_args:  defn.input_args,
      output_args: defn.output_args,
      async:       defn.async,
      # A behavior runs a program on the machine, so it needs the grant that
      # says so rather than the one that commands a single axis. Fixed rather
      # than read off the definition: a behavior that could name its own grant
      # could name a weaker one.
      call_grant:  :execute_program
    }
  end

  # Standard runtime fields present for every active behavior
  defp standard_fields do
    [
      %Property{
        id:          "runtime.active_behavior.id",
        name:        "Id",
        description: "Behavior definition ID of the currently active behavior",
        type:        :string,
        readable:    true,
        writable:    false,
        observable:  true
      },
      %Property{
        id:          "runtime.active_behavior.name",
        name:        "Name",
        description: "Human-readable name of the currently active behavior",
        type:        :string,
        readable:    true,
        writable:    false,
        observable:  true
      },
      %Property{
        id:          "runtime.active_behavior.job_id",
        name:        "JobId",
        description: "Job ID assigned to the current behavior invocation",
        type:        :string,
        readable:    true,
        writable:    false,
        observable:  true
      }
    ]
  end

  defp behavior_runtime_fields(%Definition{} = defn) do
    Enum.map(defn.runtime_fields, fn rf ->
      %Property{
        id:          "runtime.active_behavior.#{snake(rf.name)}",
        name:        pascal(rf.name),
        description: rf.description,
        type:        rf.type,
        readable:    true,
        writable:    false,
        observable:  rf.observable
      }
    end)
  end

  # "door_state" -> "DoorState"
  defp pascal(name) do
    name
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  # already snake — keep as is
  defp snake(name), do: name
end
