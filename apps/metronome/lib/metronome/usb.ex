defmodule Metronome.USB do
  @moduledoc """
  Thin, verified wrapper over the `:usb` libusb NIF for the E-Motion FPGA metronome.

  This is the device layer of the metronome app. It enumerates, opens, and
  claims the vendor-class USB device the Stage 1 FPGA firmware presents, and
  reads its configuration descriptor back to prove the two interrupt endpoints
  are exactly as defined.

  ## The device (Stage 1 firmware — `Hw.USB.VendorInterrupt`)

    * Device: vendor class `0xFF`, **VID 0x1209 / PID 0x0002**, `bcdUSB 0x0200`,
      `bMaxPacketSize0 64`, 1 configuration.
    * Config 1: 1 interface (class `0xFF`), two **interrupt** endpoints —
      **EP1 OUT (0x01)** and **EP2 IN (0x82)**, both **MPS 64**, **bInterval 1**.

  ## The DEV2/CF1 flip

  A classless `0xFF` device is enumerated by macOS but parked **unconfigured**
  (`DEV1`/`CF0` on the HealthReport) because no host driver binds it. Calling
  `open/0` here issues SET_CONFIGURATION(1) and claims interface 0 via libusb,
  which drives the device to CONFIGURED — the FPGA HealthReport should flip to
  **`DEV2`/`CF1`** and stay stable. That flip, plus a byte-correct descriptor
  readback, is the milestone-1 oracle.

  The libusb handle must stay open to hold the configured/claimed state, so
  `open/0` and `claim_and_verify/0` return the open session and the caller is
  responsible for `close/1`.

  ## Descriptor map shapes

  These are the real shapes returned by `:usb` 0.2.1 for this device (verified
  against silicon), documented here so the parsing below is unambiguous:

      # :usb.get_device_descriptor/1
      %{vendor_id: 4617, product_id: 2, class_code: 255, max_packet_size0: 64,
        usb_version: 512, num_configurations: 1, ...}

      # :usb.get_config_descriptor/2  (device, config_index 0)
      %{configuration_number: 1, attributes: 128, max_power: 100,
        interfaces: [
          %{alt_settings: [
            %{interface_number: 0, setting_number: 0, class_code: 255,
              endpoints: [
                %{address: 1,   attributes: 3, max_packet_size: 64, interval: 1, ...},
                %{address: 130, attributes: 3, max_packet_size: 64, interval: 1, ...}
              ]}
          ]}
        ]}
  """

  import Bitwise

  @vendor_id  0x1209
  @product_id 0x0002

  # bEndpointAddress values (bit 7 set = IN direction).
  @ep_out 0x01
  @ep_in  0x82

  # bmAttributes transfer-type field (bits 0-1): 3 = interrupt.
  @xfer_interrupt 0x03

  @interface 0
  @configuration 1
  @mps 64
  @interval 1

  # --- accessors (handy from IEx / for downstream milestones) ----------------

  def vendor_id,  do: @vendor_id
  def product_id, do: @product_id
  def ep_out,     do: @ep_out
  def ep_in,      do: @ep_in
  def interface,  do: @interface

  # --- discovery -------------------------------------------------------------

  @doc """
  Find our FPGA device in the libusb device list. Read-only — does not open,
  configure, or claim, so it does not disturb the device's enumerated state.
  """
  def find_device do
    case :usb.get_device_list() do
      {:ok, devices} ->
        case Enum.find(devices, &ours?/1) do
          nil -> {:error, :device_not_found}
          dev -> {:ok, dev}
        end

      {:error, reason} ->
        {:error, {:get_device_list, reason}}
    end
  end

  defp ours?(dev) do
    match?({:ok, %{vendor_id: @vendor_id, product_id: @product_id}},
           :usb.get_device_descriptor(dev))
  end

  # --- open / configure / claim ----------------------------------------------

  @doc """
  Find the device, open it, select configuration 1, and claim interface 0.

  Returns `{:ok, session}` where `session` is
  `%{device: device, handle: handle, interface: 0}`. **The handle stays open**
  so the device remains CONFIGURED (the `DEV2`/`CF1` state) until `close/1`.
  """
  def open do
    with {:ok, dev} <- find_device(),
         {:ok, handle} <- wrap(:usb.open_device(dev), :open_device),
         :ok <- wrap(:usb.set_configuration(handle, @configuration), :set_configuration),
         :ok <- wrap(:usb.claim_interface(handle, @interface), :claim_interface) do
      {:ok, %{device: dev, handle: handle, interface: @interface}}
    end
  end

  @doc "Release the claimed interface and close the handle. Reverts DEV2/CF1."
  def close(%{handle: handle, interface: iface}) do
    _ = :usb.release_interface(handle, iface)
    :usb.close_device(handle)
  end

  # --- descriptor readback ---------------------------------------------------

  @doc """
  Read configuration 0's descriptor back from the device (read-only) and return
  the parsed `:usb` map. Accepts a session or a raw device.
  """
  def config_descriptor(%{device: dev}), do: config_descriptor(dev)

  def config_descriptor(dev) do
    wrap(:usb.get_config_descriptor(dev, 0), :get_config_descriptor)
  end

  @doc """
  Assert the config descriptor presents exactly the two interrupt endpoints the
  Stage 1 firmware defines on interface 0: EP1 OUT (0x01) and EP2 IN (0x82),
  both interrupt transfer type, MPS 64, bInterval 1.

  Returns `:ok` or `{:error, {:descriptor_mismatch, %{expected:, got:}}}`.
  """
  def assert_endpoints(config) do
    got =
      config
      |> endpoints_of(@interface)
      |> Enum.map(&normalize_ep/1)
      |> Enum.sort_by(& &1.address)

    if got == expected_endpoints() do
      :ok
    else
      {:error, {:descriptor_mismatch, %{expected: expected_endpoints(), got: got}}}
    end
  end

  defp expected_endpoints do
    [
      %{address: @ep_out, transfer_type: @xfer_interrupt, max_packet_size: @mps, interval: @interval},
      %{address: @ep_in,  transfer_type: @xfer_interrupt, max_packet_size: @mps, interval: @interval}
    ]
    |> Enum.sort_by(& &1.address)
  end

  defp normalize_ep(ep) do
    %{
      address:         Map.fetch!(ep, :address),
      transfer_type:   band(Map.fetch!(ep, :attributes), 0x03),
      max_packet_size: Map.fetch!(ep, :max_packet_size),
      interval:        Map.fetch!(ep, :interval)
    }
  end

  @doc false
  # Endpoints of the first (and only) alt setting matching `interface_number`.
  def endpoints_of(config, interface_number) do
    config
    |> Map.get(:interfaces, [])
    |> Enum.flat_map(&Map.get(&1, :alt_settings, []))
    |> Enum.filter(&(Map.get(&1, :interface_number) == interface_number))
    |> Enum.flat_map(&Map.get(&1, :endpoints, []))
  end

  # --- milestone-1 oracle ----------------------------------------------------

  @doc """
  Milestone-1 one-shot: open + SET_CONFIGURATION(1) + claim interface 0, read
  the config descriptor back, and assert the two interrupt endpoints.

  On success returns `{:ok, session, report}` with the handle **still open** so
  the `DEV2`/`CF1` state persists for the HealthReport cross-check — the caller
  must `close/1` when done. On any failure the handle (if opened) is closed so
  it is never leaked, and `{:error, reason}` is returned.
  """
  def claim_and_verify do
    case open() do
      {:ok, session} ->
        case verify(session) do
          {:ok, report} ->
            {:ok, session, report}

          {:error, _} = err ->
            close(session)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp verify(session) do
    with {:ok, config} <- config_descriptor(session),
         :ok <- assert_endpoints(config) do
      {:ok,
       %{
         vendor_id:     @vendor_id,
         product_id:    @product_id,
         configuration: Map.get(config, :configuration_number),
         endpoints:     endpoints_of(config, @interface)
       }}
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp wrap(:ok, _op), do: :ok
  defp wrap({:ok, _} = ok, _op), do: ok
  defp wrap({:error, reason}, op), do: {:error, {op, reason}}
end
