defmodule Metronome do
  @moduledoc """
  Metronome — host-side interface to the ExMo FPGA motion metronome over USB.

  The FPGA (ULX3S ECP5) is the hard-real-time metronome: it holds the trajectory
  look-ahead buffer, interpolates each servo cycle, and runs the CANopen cyclic
  engine (SYNC + RPDO/TPDO) entirely on its own clock. This umbrella app is the
  host side of that link and speaks **USB only** — it streams setpoint/motion
  windows down (interrupt EP1 OUT) and reads feedback windows up (interrupt
  EP2 IN). It never computes CAN frames; that is the FPGA's job, derived from
  the setpoint/motion data we send.

  ## Milestone 1 (this slice) — descriptor-readback oracle

  Prove the host can drive the Stage 1 device to CONFIGURED and that its
  descriptor is byte-correct:

      # Board flashed with the Stage 1 bitstream, enumerated (DEV1/CF0):
      {:ok, session, report} = Metronome.claim_and_verify()
      report.endpoints
      # => the two interrupt endpoints (EP1 OUT, EP2 IN)

      # The HealthReport serial should now show DEV2/CF1 while the handle is held.
      # When done:
      Metronome.close(session)

  See `Metronome.USB` for the device-layer detail.
  """

  defdelegate open,                         to: Metronome.USB
  defdelegate claim_and_verify,             to: Metronome.USB
  defdelegate close(session),               to: Metronome.USB
  defdelegate find_device,                  to: Metronome.USB
  defdelegate config_descriptor(dev_or_session), to: Metronome.USB
end
