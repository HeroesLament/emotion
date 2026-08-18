defmodule Metronome.USBTest do
  use ExUnit.Case, async: true

  alias Metronome.USB

  # The exact config-descriptor map the Stage 1 device returns via :usb 0.2.1,
  # captured from silicon. Used to exercise the parsing/assertion logic with no
  # hardware attached.
  @config %{
    attributes: 128,
    extra: "",
    configuration_number: 1,
    description_string_index: 0,
    max_power: 100,
    interfaces: [
      %{
        alt_settings: [
          %{
            extra: "",
            class_code: 255,
            sub_class_code: 0,
            protocol_code: 0,
            description_string_index: 0,
            interface_number: 0,
            setting_number: 0,
            endpoints: [
              %{attributes: 3, extra: "", address: 1, refresh: 0, interval: 1, max_packet_size: 64, synch_address: 0},
              %{attributes: 3, extra: "", address: 130, refresh: 0, interval: 1, max_packet_size: 64, synch_address: 0}
            ]
          }
        ]
      }
    ]
  }

  describe "endpoints_of/2" do
    test "pulls both endpoints from interface 0" do
      eps = USB.endpoints_of(@config, 0)
      assert length(eps) == 2
      assert Enum.map(eps, & &1.address) |> Enum.sort() == [1, 130]
    end

    test "returns [] for an interface that does not exist" do
      assert USB.endpoints_of(@config, 7) == []
    end
  end

  describe "assert_endpoints/1" do
    test "passes for the real Stage 1 descriptor" do
      assert USB.assert_endpoints(@config) == :ok
    end

    test "fails when an endpoint's max packet size is wrong" do
      bad = put_in_first_endpoint(@config, :max_packet_size, 32)
      assert {:error, {:descriptor_mismatch, %{expected: _, got: _}}} =
               USB.assert_endpoints(bad)
    end

    test "fails when an endpoint is not interrupt type" do
      # attributes 2 = bulk transfer type
      bad = put_in_first_endpoint(@config, :attributes, 2)
      assert {:error, {:descriptor_mismatch, _}} = USB.assert_endpoints(bad)
    end

    test "fails when the IN endpoint is missing" do
      bad = update_in(@config, [:interfaces, Access.at(0), :alt_settings, Access.at(0), :endpoints], fn eps ->
        Enum.reject(eps, &(&1.address == 130))
      end)

      assert {:error, {:descriptor_mismatch, _}} = USB.assert_endpoints(bad)
    end

    test "fails when bInterval is wrong" do
      bad = put_in_first_endpoint(@config, :interval, 4)
      assert {:error, {:descriptor_mismatch, _}} = USB.assert_endpoints(bad)
    end
  end

  # --- Hardware-in-the-loop (requires the Stage 1 board; excluded by default) --

  @tag :hardware
  test "claim_and_verify/0 drives the real device to configured and reads it back" do
    assert {:ok, session, report} = USB.claim_and_verify()

    try do
      assert report.vendor_id == 0x1209
      assert report.product_id == 0x0002
      assert report.configuration == 1
      assert length(report.endpoints) == 2
      addresses = report.endpoints |> Enum.map(& &1.address) |> Enum.sort()
      assert addresses == [0x01, 0x82]
    after
      USB.close(session)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp put_in_first_endpoint(config, key, value) do
    update_in(
      config,
      [:interfaces, Access.at(0), :alt_settings, Access.at(0), :endpoints, Access.at(0)],
      &Map.put(&1, key, value)
    )
  end
end
