defmodule EMotion.Drive.ObjectDictionary do
  @moduledoc """
  The optional half of the drive contract: raw object access.

  `protocol/DESIGN.md` originally proposed `read/3` and `write/4` as *the*
  drive contract. They are not, because a PWM actuator has no object
  dictionary and would have to fake one. But they are exactly right for the
  drives that do have one, and discarding them would have thrown away
  something the rest of the stack needs.

  Three things need raw object access, and none of them are motion:

  * **Configuration.** Node id, bitrate, gear ratio, current limits — all of
    it lives in the dictionary, and all of it is written once at commissioning
    rather than every cycle.
  * **Tuning.** Reading a following-error window or a current loop gain to
    show it in the Studio, and writing it back when someone drags a slider.
  * **The SDO tunnel.** `protocol/METRONOME.md` describes acyclic traffic
    riding in the guard band between cyclic frames. What flows through that
    tunnel is object reads and writes; this behaviour is its near end.

  Motion never comes through here. A setpoint is `set_target_position/2` on
  `EMotion.Drive`, which an implementation maps to an RPDO. Writing 0x607A by
  hand every cycle would be an SDO round trip per setpoint — measured at ~1 ms,
  which does not fit in a 2 ms budget six times over.

  ## Both of these are slow and both of them can fail

  Unlike everything in `EMotion.Drive`, these are synchronous, they go to the
  wire, and they block. Call them at commissioning, on a settings screen, or
  from a background task — never from a control loop, and never from a process
  that a control loop is waiting on.
  """

  @typedoc "Object dictionary index, 0x1000-0x9FFF in CiA 301 terms."
  @type index :: 0..0xFFFF

  @typedoc "Sub-index. 0 is the entry itself or its element count."
  @type sub :: 0..255

  @typedoc """
  Why an object access failed.

  `:timeout` and `:aborted` are different facts and worth keeping apart: a
  timeout means the drive never answered, an abort means it answered with a
  refusal and a code. Retrying is reasonable for one and not the other.
  """
  @type reason ::
          :timeout
          | {:aborted, code :: 0..0xFFFFFFFF}
          | :not_found
          | :read_only
          | :offline
          | term()

  @doc "Read one object. Synchronous, goes to the wire, ~1 ms on a healthy bus."
  @callback read(EMotion.Drive.axis_id(), index(), sub()) ::
              {:ok, term()} | {:error, reason()}

  @doc """
  Write one object. Synchronous, goes to the wire, and may be refused by the
  drive for reasons the controller cannot know in advance — a value out of
  range, or an object that is read-only in the drive's current state.
  """
  @callback write(EMotion.Drive.axis_id(), index(), sub(), term()) ::
              :ok | {:error, reason()}
end
