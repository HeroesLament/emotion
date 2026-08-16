defmodule ExProto.DispatchTest do
  @moduledoc """
  The protocol, exercised end to end with no socket.

  Every test below builds a session, hands it a decoded request, and inspects
  what comes back. That is the whole point of keeping dispatch pure: the
  protocol is fully covered before a transport exists, and when one arrives it
  has nothing to get wrong except moving bytes.
  """

  use ExUnit.Case, async: true

  alias ExMo.InformationModel
  alias ExMo.Projection.JSONRPC
  alias ExMo.Projection.JSONRPC.OpenRPC
  alias ExProto.{Dispatch, Nodes, Session}
  alias ExProto.Source.Static

  setup do
    {:ok, model} = InformationModel.compiled_model()
    {:ok, table} = JSONRPC.project(model)

    {:ok, source} =
      Static.start_link(
        values: %{
          "axes.j1.position" => 0.5,
          "axes.j1.target_position" => 0.0,
          "axes.j1.velocity" => 0.0,
          "axes.j1.drive_state" => "operation_enabled",
          "axes.j1.fault_code" => 0,
          "axes.j2.position" => -1.25,
          "axes.j2.target_position" => 0.0
        },
        clamp: %{"axes.j1.target_position" => {-3.05, 3.05}},
        reject: ["axes.j2.target_position"]
      )

    session =
      Session.new(table: table, source: {Static, source}, principal: principal(:maintainer))

    {:ok, session: session, source: source, table: table}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # No database. ExAuth.Principal is a plain struct built from an account's id,
  # username and role, so the pure protocol tests stay pure — a test that has
  # to migrate a schema to check an authorisation rule will not be run often
  # enough to matter.
  defp principal(role) do
    ExAuth.Principal.new(%{id: 1, username: "test-#{role}", role: role})
  end

  defp session_as(role, %{table: table, source: source}) do
    Session.new(table: table, source: {Static, source}, principal: principal(role))
  end

  defp call(session, method, params \\ %{}, id \\ 1) do
    request = %{"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id}
    Dispatch.handle(request, session)
  end

  defp notify(session, method, params \\ %{}) do
    Dispatch.handle(%{"jsonrpc" => "2.0", "method" => method, "params" => params}, session)
  end

  defp ready(session) do
    {:reply, _, session} =
      call(session, "initialize", %{
        "protocolVersion" => OpenRPC.protocol_version(),
        "clientInfo" => %{"name" => "test", "version" => "0"}
      })

    session
  end

  # A session bound to a particular watchdog. Held commands are the only thing
  # that needs one, so the ordinary sessions above leave it at its default.
  defp held_session(role, %{table: table, source: source, jog: jog}) do
    Session.new(
      table: table,
      source: {Static, source},
      principal: ExAuth.Principal.new(%{id: 1, username: "test-#{role}", role: role}),
      jog: jog
    )
    |> ready()
  end

  defp jog(session, velocity, extra \\ %{}, node_id \\ "axes.j1.jog") do
    arguments = Map.merge(%{"velocity" => velocity}, extra)
    call(session, "nodes/call", %{"nodeId" => node_id, "arguments" => arguments}, 2)
  end

  defp wait_until(fun, remaining \\ 200) do
    cond do
      fun.() ->
        :ok

      remaining <= 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(5)
        wait_until(fun, remaining - 5)
    end
  end

  defp result({:reply, %{"result" => result}, _session}), do: result
  defp error({:reply, %{"error" => error}, _session}), do: error

  # ── envelope ──────────────────────────────────────────────────────────────

  describe "JSON-RPC 2.0 envelope" do
    test "a response echoes the request id", %{session: session} do
      assert {:reply, %{"jsonrpc" => "2.0", "id" => 42}, _} =
               call(ready(session), "nodes/browse", %{}, 42)
    end

    test "string ids work as well as integers", %{session: session} do
      assert {:reply, %{"id" => "abc"}, _} = call(ready(session), "nodes/browse", %{}, "abc")
    end

    test "a notification gets no response at all", %{session: session} do
      assert {:noreply, _session} = notify(ready(session), "nodes/browse")
    end

    test "a notification that fails still gets no response", %{session: session} do
      # The one implementations most often get wrong. Returning an error to a
      # message with no id hands the client something it cannot correlate and
      # may mistake for a reply to a different call.
      assert {:noreply, _session} = notify(session, "no/such/method")
    end

    test "an unknown method is -32601", %{session: session} do
      assert %{"code" => -32_601} = error(call(ready(session), "totally/made/up"))
    end

    test "non-object params are -32602", %{session: session} do
      request = %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => [1, 2], "id" => 1}
      assert {:reply, %{"error" => %{"code" => -32_602}}, _} = Dispatch.handle(request, session)
    end

    test "a request that is not a request is -32600", %{session: session} do
      assert {:reply, %{"error" => %{"code" => -32_600}}, _} =
               Dispatch.handle(%{"nope" => true}, session)
    end

    test "malformed JSON is -32700 with a null id", %{session: session} do
      assert {:reply, %{"id" => nil, "error" => %{"code" => -32_700}}, _} =
               Dispatch.handle_payload("{not json", session)
    end

    test "trailing garbage after valid JSON is still a parse error", %{session: session} do
      assert {:reply, %{"error" => %{"code" => -32_700}}, _} =
               Dispatch.handle_payload(~s({"jsonrpc":"2.0","method":"x","id":1} trailing), session)
    end
  end

  describe "batches" do
    test "a batch returns one response per request", %{session: session} do
      session = ready(session)

      batch = [
        %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}, "id" => 1},
        %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}, "id" => 2}
      ]

      assert {:reply, [%{"id" => 1}, %{"id" => 2}], _} = Dispatch.handle(batch, session)
    end

    test "notifications inside a batch produce no entries", %{session: session} do
      session = ready(session)

      batch = [
        %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}},
        %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}, "id" => 7}
      ]

      assert {:reply, [%{"id" => 7}], _} = Dispatch.handle(batch, session)
    end

    test "a batch of only notifications returns nothing, not an empty array", %{session: session} do
      session = ready(session)
      batch = [%{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}}]

      assert {:noreply, _} = Dispatch.handle(batch, session)
    end

    test "an empty batch is a single invalid-request error", %{session: session} do
      assert {:reply, %{"error" => %{"code" => -32_600}}, _} = Dispatch.handle([], session)
    end

    test "state carries across a batch", %{session: session} do
      # initialize then browse, in one batch. The second must see the first.
      batch = [
        %{
          "jsonrpc" => "2.0",
          "method" => "initialize",
          "params" => %{"protocolVersion" => OpenRPC.protocol_version()},
          "id" => 1
        },
        %{"jsonrpc" => "2.0", "method" => "nodes/browse", "params" => %{}, "id" => 2}
      ]

      assert {:reply, [%{"result" => _}, %{"result" => _}], _} = Dispatch.handle(batch, session)
    end
  end

  # ── handshake ─────────────────────────────────────────────────────────────

  describe "initialize" do
    test "accepts the version this build speaks", %{session: session} do
      result =
        result(
          call(session, "initialize", %{"protocolVersion" => OpenRPC.protocol_version()})
        )

      assert result["protocolVersion"] == OpenRPC.protocol_version()
      assert result["capabilities"]["nodes"]["count"] > 0
    end

    test "refuses an unknown version and says what it does speak", %{session: session} do
      error = error(call(session, "initialize", %{"protocolVersion" => "1999-01-01"}))

      assert error["code"] == -32_002
      # Actionable: an operator can be told to update something specific.
      assert error["data"]["supported"] == [OpenRPC.protocol_version()]
    end

    test "reports the time base so a client knows not to overlay timestamps",
         %{session: session} do
      result = result(call(session, "initialize", %{"protocolVersion" => OpenRPC.protocol_version()}))

      assert result["capabilities"]["timeBase"] == "local"
    end

    test "initializing twice is an error", %{session: session} do
      session = ready(session)

      assert %{"code" => -32_001} =
               error(call(session, "initialize", %{"protocolVersion" => OpenRPC.protocol_version()}))
    end

    test "every other method is refused before initialize", %{session: session} do
      for method <- ~w(nodes/browse nodes/read nodes/write nodes/subscribe nodes/unsubscribe) do
        assert %{"code" => -32_000} = error(call(session, method, %{})),
               "#{method} should require initialization"
      end
    end
  end

  # ── browse ────────────────────────────────────────────────────────────────

  describe "browse" do
    test "with no nodeId browses from the root", %{session: session} do
      result = result(call(ready(session), "nodes/browse"))

      assert result["node"]["nodeId"] == "exmo"
      assert Enum.any?(result["children"], &(&1["nodeId"] == "axes"))
    end

    test "returns direct children only", %{session: session} do
      result = result(call(ready(session), "nodes/browse", %{"nodeId" => "axes"}))
      ids = Enum.map(result["children"], & &1["nodeId"])

      assert "axes.j1" in ids
      # A grandchild would mean the whole model arrives on every browse.
      refute "axes.j1.position" in ids
    end

    test "a property descriptor carries its schema and access flags", %{session: session} do
      result = result(call(ready(session), "nodes/browse", %{"nodeId" => "axes.j1"}))
      position = Enum.find(result["children"], &(&1["name"] == "Position"))

      assert position["schema"]["type"] == "number"
      assert position["readable"]
      assert position["observable"]
      refute position["writable"]
    end

    test "descriptors state the SI unit and the display hint separately",
         %{session: session} do
      result = result(call(ready(session), "nodes/browse", %{"nodeId" => "axes.j1"}))
      position = Enum.find(result["children"], &(&1["name"] == "Position"))

      assert position["unit"] == "rad"
      assert position["displayUnit"] == "degrees"
    end

    test "an unknown node is -32003", %{session: session} do
      assert %{"code" => -32_003} =
               error(call(ready(session), "nodes/browse", %{"nodeId" => "axes.j99"}))
    end
  end

  # ── read ──────────────────────────────────────────────────────────────────

  describe "read" do
    test "returns values in request order", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/read", %{
            "nodeIds" => ["axes.j2.position", "axes.j1.position"]
          })
        )

      assert [%{"nodeId" => "axes.j2.position", "value" => -1.25}, %{"value" => 0.5}] =
               result["values"]
    end

    test "one bad node does not fail the batch", %{session: session} do
      # A pendant should show five live values and one greyed cell, not nothing.
      result =
        result(
          call(ready(session), "nodes/read", %{
            "nodeIds" => ["axes.j1.position", "axes.nope", "axes.j2.position"]
          })
        )

      assert [good, bad, also_good] = result["values"]
      assert good["value"] == 0.5
      assert bad["error"]["code"] == -32_003
      assert also_good["value"] == -1.25
    end

    test "results are always the same length as the request", %{session: session} do
      ids = ["axes.j1.position", "axes.nope", "axes.j1", "axes.j1.velocity"]
      result = result(call(ready(session), "nodes/read", %{"nodeIds" => ids}))

      assert length(result["values"]) == length(ids)
    end

    test "reading an object rather than a property is not readable", %{session: session} do
      result = result(call(ready(session), "nodes/read", %{"nodeIds" => ["axes.j1"]}))

      assert [%{"error" => %{"code" => -32_004}}] = result["values"]
    end

    test "values carry a timestamp", %{session: session} do
      result = result(call(ready(session), "nodes/read", %{"nodeIds" => ["axes.j1.position"]}))

      assert {:ok, _dt, _} = DateTime.from_iso8601(hd(result["values"])["timestamp"])
    end

    test "a missing nodeIds is invalid params", %{session: session} do
      assert %{"code" => -32_602} = error(call(ready(session), "nodes/read", %{}))
    end
  end

  # ── write ─────────────────────────────────────────────────────────────────

  describe "write" do
    test "writes a value and reads it back", %{session: session} do
      session = ready(session)

      call(session, "nodes/write", %{
        "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.5}]
      })

      result = result(call(session, "nodes/read", %{"nodeIds" => ["axes.j1.target_position"]}))
      assert hd(result["values"])["value"] == 1.5
    end

    test "reports the applied value, not the requested one", %{session: session} do
      # The source clamps to the joint limit. A client told what it asked for
      # would draw the arm somewhere it is not.
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 99.0}]
          })
        )

      assert [%{"ok" => true, "value" => 3.05}] = result["results"]
    end

    test "a read-only node is -32005", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [%{"nodeId" => "axes.j1.position", "value" => 1.0}]
          })
        )

      assert [%{"ok" => false, "error" => %{"code" => -32_005}}] = result["results"]
    end

    test "a value that fails the node's schema is -32007", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => "sideways"}]
          })
        )

      assert [%{"ok" => false, "error" => %{"code" => -32_007, "message" => message}}] =
               result["results"]

      # Actionable rather than merely "invalid".
      assert message =~ "expected number"
    end

    test "a refused write is -32010", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [%{"nodeId" => "axes.j2.target_position", "value" => 0.5}]
          })
        )

      assert [%{"ok" => false, "error" => %{"code" => -32_010}}] = result["results"]
    end

    test "a batch half-succeeds and says which half", %{session: session} do
      # Explicitly not atomic. Rolling back a value that already reached a
      # drive is not something this layer can honestly offer.
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [
              %{"nodeId" => "axes.j1.target_position", "value" => 1.0},
              %{"nodeId" => "axes.j2.target_position", "value" => 1.0}
            ]
          })
        )

      assert [%{"ok" => true}, %{"ok" => false}] = result["results"]

      # And the first write really did land.
      read = result(call(ready(session), "nodes/read", %{"nodeIds" => ["axes.j1.target_position"]}))
      assert hd(read["values"])["value"] == 1.0
    end

    test "an unknown node is -32003", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/write", %{
            "writes" => [%{"nodeId" => "nope", "value" => 1}]
          })
        )

      assert [%{"error" => %{"code" => -32_003}}] = result["results"]
    end
  end

  # ── subscribe ─────────────────────────────────────────────────────────────

  describe "subscribe" do
    test "returns an id and the granted rate", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/subscribe", %{
            "nodeIds" => ["axes.j1.position"],
            "rateHz" => 30
          })
        )

      assert result["subscriptionId"] =~ ~r/^sub_/
      assert result["rateHz"] == 30.0
    end

    test "the granted rate is capped, not echoed", %{session: session} do
      result =
        result(
          call(ready(session), "nodes/subscribe", %{
            "nodeIds" => ["axes.j1.position"],
            "rateHz" => 5000
          })
        )

      assert result["rateHz"] == 1000.0
    end

    test "a non-observable node is refused rather than silently never sent",
         %{session: session} do
      # A subscription that produces nothing is indistinguishable from a
      # broken controller.
      assert %{"code" => -32_006} =
               error(
                 call(ready(session), "nodes/subscribe", %{
                   "nodeIds" => ["axes.j1.target_position"]
                 })
               )
    end

    test "an unknown node is refused", %{session: session} do
      assert %{"code" => -32_003} =
               error(call(ready(session), "nodes/subscribe", %{"nodeIds" => ["nope"]}))
    end

    test "the subscription limit is enforced", %{session: session} do
      session =
        Enum.reduce(1..Session.max_subscriptions(), ready(session), fn _, session ->
          {:reply, _, session} =
            call(session, "nodes/subscribe", %{"nodeIds" => ["axes.j1.position"]})

          session
        end)

      assert %{"code" => -32_008} =
               error(call(session, "nodes/subscribe", %{"nodeIds" => ["axes.j1.position"]}))
    end

    test "unsubscribe is idempotent", %{session: session} do
      session = ready(session)

      # Never existed.
      assert %{} = result(call(session, "nodes/unsubscribe", %{"subscriptionId" => "sub_999"}))

      {:reply, %{"result" => %{"subscriptionId" => id}}, session} =
        call(session, "nodes/subscribe", %{"nodeIds" => ["axes.j1.position"]})

      {:reply, _, session} = call(session, "nodes/unsubscribe", %{"subscriptionId" => id})
      # And again.
      assert %{} = result(call(session, "nodes/unsubscribe", %{"subscriptionId" => id}))
      assert session.subscriptions == %{}
    end
  end

  # ── the codes match the published document ────────────────────────────────

  describe "error codes match the generated document" do
    test "every code the implementation uses is declared in the OpenRPC document" do
      # The document is the contract. An implementation returning a code the
      # document does not publish is one a client cannot handle.
      {:ok, model} = InformationModel.compiled_model()
      {:ok, doc} = OpenRPC.document(model)

      declared =
        doc["components"]["errors"]
        |> Map.values()
        |> Enum.map(& &1["code"])
        |> MapSet.new()

      for {name, code} <- Nodes.error_codes() do
        assert MapSet.member?(declared, code),
               "#{name} uses #{code}, which the OpenRPC document does not declare"
      end
    end

    test "every declared code is one the implementation can produce" do
      {:ok, model} = InformationModel.compiled_model()
      {:ok, doc} = OpenRPC.document(model)

      used = Nodes.error_codes() |> Map.values() |> MapSet.new()

      for {name, %{"code" => code}} <- doc["components"]["errors"] do
        assert MapSet.member?(used, code),
               "#{name} (#{code}) is declared but the implementation never returns it"
      end
    end
  end

  # ── authorisation ─────────────────────────────────────────────────────────

  describe "grants on read" do
    test "an observer may read state", context do
      session = :observer |> session_as(context) |> ready()
      {:reply, response, _} = call(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})

      assert [%{"value" => 0.5}] = response["result"]["values"]
    end

    test "a principal holding nothing is refused, per node", context do
      # :nobody is not a role, so it resolves to an empty grant set. This is the
      # fail-closed path: an unrecognised role must grant nothing rather than
      # falling through to permissive defaults.
      session = :nobody |> session_as(context) |> ready()
      {:reply, response, _} = call(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})

      assert [%{"error" => error}] = response["result"]["values"]
      assert error["code"] == Nodes.error_codes().forbidden
      assert error["data"]["requiredGrant"] == "read_state"
    end

    test "a refusal names the missing grant so an operator knows what to ask for", context do
      session = :nobody |> session_as(context) |> ready()
      {:reply, response, _} = call(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})

      assert [%{"error" => %{"message" => message}}] = response["result"]["values"]
      assert message =~ "read_state"
    end
  end

  describe "grants on write" do
    test "an operator may command a setpoint", context do
      session = :operator |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.0}]
        })

      assert [%{"ok" => true, "value" => 1.0}] = response["result"]["results"]
    end

    test "an observer may not", context do
      session = :observer |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.0}]
        })

      assert [%{"ok" => false, "error" => error}] = response["result"]["results"]
      assert error["code"] == Nodes.error_codes().forbidden
      assert error["data"]["requiredGrant"] == "write_setpoint"
    end

    test "a safety officer may not command motion either", context do
      # The role exists to configure safety, and the whole reason it is off the
      # observer/operator ladder is that it must not be able to move the arm.
      session = :safety_officer |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 1.0}]
        })

      assert [%{"ok" => false, "error" => %{"code" => code}}] = response["result"]["results"]
      assert code == Nodes.error_codes().forbidden
    end

    test "a refused write does not reach the source", context do
      session = :observer |> session_as(context) |> ready()

      call(session, "nodes/write", %{
        "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => 2.5}]
      })

      # The value the source still holds is the one it started with. An
      # authorisation check that runs after the effect is not a check.
      reader = :maintainer |> session_as(context) |> ready()

      {:reply, response, _} =
        call(reader, "nodes/read", %{"nodeIds" => ["axes.j1.target_position"]})

      # +0.0, not 0.0: OTP 27+ warns that a bare 0.0 pattern matches only +0.0.
      assert [%{"value" => +0.0}] = response["result"]["values"]
    end

    test "authorisation is checked before validation", context do
      # A caller without the grant must not learn whether its value would have
      # been accepted — the refusal is the same for a valid and an invalid one.
      session = :observer |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/write", %{
          "writes" => [%{"nodeId" => "axes.j1.target_position", "value" => "not a number"}]
        })

      assert [%{"ok" => false, "error" => %{"code" => code}}] = response["result"]["results"]
      assert code == Nodes.error_codes().forbidden
    end
  end

  describe "grants on subscribe" do
    test "an observer may subscribe to what it may read", context do
      session = :observer |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/subscribe", %{"nodeIds" => ["axes.j1.position"]})

      assert response["result"]["subscriptionId"]
    end

    test "a principal holding nothing may not subscribe", context do
      # Without this, a read an observer is denied could be obtained thirty
      # times a second by subscribing to it instead.
      session = :nobody |> session_as(context) |> ready()

      {:reply, response, _} =
        call(session, "nodes/subscribe", %{"nodeIds" => ["axes.j1.position"]})

      assert response["error"]["code"] == Nodes.error_codes().forbidden
      assert response["error"]["data"]["requiredGrant"] == "read_state"
    end
  end

  describe "a session with no principal" do
    test "is refused everything rather than permitted everything", %{table: table, source: source} do
      session =
        Session.new(table: table, source: {Static, source}, principal: nil) |> ready()

      {:reply, response, _} = call(session, "nodes/read", %{"nodeIds" => ["axes.j1.position"]})
      assert [%{"error" => %{"code" => code}}] = response["result"]["values"]
      assert code == Nodes.error_codes().forbidden
    end
  end

  # ── commands ──────────────────────────────────────────────────────────────

  describe "nodes/call" do
    test "an operator may enable an axis", context do
      session = :operator |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j1.enable"}, 2)

      # An acceptance, not a result. The machine may still refuse; that shows
      # up on `state`, not here.
      assert response["result"]["accepted"] == true
      assert response["result"]["async"] == true
    end

    test "an observer may not", context do
      session = :observer |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j1.enable"}, 2)

      assert response["error"]["code"] == Nodes.error_codes().forbidden
      assert response["error"]["data"]["requiredGrant"] == "enable_drives"
    end

    test "a property is not callable", context do
      session = :operator |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j1.position"}, 2)

      assert response["error"]["code"] == Nodes.error_codes().not_callable
    end

    test "an unknown node is unknown, not uncallable", context do
      session = :operator |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j9.enable"}, 2)

      assert response["error"]["code"] == Nodes.error_codes().unknown_node
    end

    test "the command reaches the source with its arguments", %{source: source} = context do
      session = :operator |> session_as(context) |> ready()

      {:reply, _response, _} =
        call(session, "nodes/call", %{"nodeId" => "axes.j1.home", "arguments" => %{"speed" => 0.2}}, 2)

      # An acceptance says nothing about arrival, so this checks the far side.
      assert [{"axes.j1.home", %{"speed" => 0.2}}] = Static.calls(source)
    end

    test "a source with no commands says so rather than crashing", %{table: table} do
      # The call callback is optional; a source that does not implement it must
      # produce an error, not a crash.
      defmodule Commandless do
        @behaviour ExProto.Source
        @impl true
        def read(_id, _arg), do: {:error, :unknown_node}
        @impl true
        def write(_id, _value, _arg), do: {:error, :not_writable}
      end

      session =
        ExProto.Session.new(
          table: table,
          source: {Commandless, nil},
          principal: ExAuth.Principal.new(%{id: 1, username: "op", role: :operator})
        )
        |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j1.enable"}, 2)

      assert response["error"]["code"] == Nodes.error_codes().not_callable
    end

    test "authorisation is checked before the source is asked anything", context do
      # An observer calling a node this source could not execute anyway must
      # still be told it lacks the grant — otherwise the error leaks which
      # commands the controller happens to have bound.
      session = :observer |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{"nodeId" => "axes.j1.home"}, 2)

      assert response["error"]["code"] == Nodes.error_codes().forbidden
    end

    test "a missing nodeId is invalid params", context do
      session = :operator |> session_as(context) |> ready()

      {:reply, response, _} = call(session, "nodes/call", %{}, 2)

      assert response["error"]["code"] == -32_602
    end
  end

  # ── held commands ─────────────────────────────────────────────────────────

  describe "nodes/call, held" do
    setup do
      # A watchdog per test, named per test. These run async, and a shared one
      # would let a hold taken in one test refuse a jog in another — a failure
      # that would appear and disappear with the scheduler.
      name = :"jog_#{System.unique_integer([:positive])}"
      pid = start_supervised!({ExProto.Jog, name: name})

      {:ok, jog: name, jog_pid: pid}
    end

    test "an operator may jog, and is told the deadline it must beat", context do
      session = held_session(:operator, context)

      {:reply, response, _} = jog(session, 0.1)

      assert response["result"]["accepted"] == true
      assert response["result"]["deadlineMs"] == ExMo.Schema.Method.watchdog_deadline_ms().default
    end

    test "an observer may not", context do
      session = held_session(:observer, context)

      {:reply, response, _} = jog(session, 0.1)

      assert response["error"]["code"] == Nodes.error_codes().forbidden
      assert response["error"]["data"]["requiredGrant"] == "jog"
    end

    test "the deadline is clamped, and the granted one is what comes back", context do
      session = held_session(:operator, context)
      bounds = ExMo.Schema.Method.watchdog_deadline_ms()

      {:reply, slow, _} = jog(session, 0.1, %{"deadlineMs" => 10_000})
      assert slow["result"]["deadlineMs"] == bounds.max

      {:reply, fast, _} = jog(session, 0.1, %{"deadlineMs" => 1})
      assert fast["result"]["deadlineMs"] == bounds.min
    end

    test "a jog with no velocity is invalid params rather than a hold", context do
      session = held_session(:operator, context)

      {:reply, response, _} =
        call(session, "nodes/call", %{"nodeId" => "axes.j1.jog", "arguments" => %{}}, 2)

      assert response["error"]["code"] == -32_602
      assert ExProto.Jog.holder("axes.j1", context.jog) == :none
    end

    test "the setpoint reaches the source", %{source: source} = context do
      session = held_session(:operator, context)

      {:reply, _, _} = jog(session, 0.25)

      assert [{"axes.j1.jog", %{"velocity" => 0.25}}] = Static.calls(source)
    end

    test "one session at a time holds an axis", context do
      first = held_session(:operator, context)
      {:reply, accepted, _} = jog(first, 0.1)
      assert accepted["result"]["accepted"] == true

      # A second session, which here means a second process: the hold is on the
      # connection, and two requests from one process are the same holder.
      second = held_session(:operator, context)

      response =
        Task.async(fn ->
          {:reply, response, _} = jog(second, 0.1)
          response
        end)
        |> Task.await()

      assert response["error"]["code"] == Nodes.error_codes().node_held
    end

    test "when the assertions stop, the axis is commanded to zero",
         %{source: source} = context do
      session = held_session(:operator, context)

      {:reply, _, _} = jog(session, 0.4, %{"deadlineMs" => 50})
      assert [{"axes.j1.jog", %{"velocity" => 0.4}}] = Static.calls(source)

      # Nothing further is sent. This is the whole point: a client that stops
      # asserting — because it crashed, or because the link dropped — must not
      # leave the axis moving.
      Process.sleep(150)

      assert [_asserted, {"axes.j1.jog", %{"velocity" => +0.0}}] = Static.calls(source)
      assert ExProto.Jog.holder("axes.j1", context.jog) == :none
    end

    test "when the holder dies, the axis is commanded to zero",
         %{source: source, jog_pid: watchdog} = context do
      session = held_session(:operator, context)

      holder =
        spawn(fn ->
          {:reply, _, _} = jog(session, 0.4, %{"deadlineMs" => 500})
          receive do: (:never -> :ok)
        end)

      ref = Process.monitor(holder)
      wait_until(fn -> ExProto.Jog.holder("axes.j1", context.jog) == {:ok, holder} end)

      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      # Long before the 500ms deadline: losing the client is itself the signal,
      # and waiting out the timer would be 500ms of motion nobody is watching.
      :sys.get_state(watchdog)
      assert [_asserted, {"axes.j1.jog", %{"velocity" => +0.0}}] = Static.calls(source)
    end

    test "an ordinary command supersedes a hold", %{source: source} = context do
      first = held_session(:operator, context)
      {:reply, _, _} = jog(first, 0.4, %{"deadlineMs" => 500})

      # A stop from someone who can see the machine outranks a joystick held by
      # someone who may not be in the room.
      second = held_session(:operator, context)

      Task.async(fn ->
        {:reply, response, _} = call(second, "nodes/call", %{"nodeId" => "axes.j1.stop"}, 2)
        assert response["result"]["accepted"] == true

        # And the axis is free again, rather than held by a session that has
        # stopped asserting.
        {:reply, response, _} = jog(second, 0.1)
        assert response["result"]["accepted"] == true
      end)
      |> Task.await()

      # No zero setpoint raced the stop in. The stop is the command.
      assert [
               {"axes.j1.jog", %{"velocity" => 0.4}},
               {"axes.j1.stop", _},
               {"axes.j1.jog", %{"velocity" => 0.1}} | _the_task_exiting
             ] = Static.calls(source)
    end

    test "a jog the source refuses leaves no hold behind", context do
      # A drive that is not enabled refuses a velocity setpoint. What must not
      # happen is the axis being locked against every other session anyway,
      # until a deadline nobody is asserting against runs out.
      {:ok, refusing} = Static.start_link(values: %{}, reject: ["axes.j1.jog"])
      session = held_session(:operator, %{context | source: refusing})

      {:reply, response, _} = jog(session, 0.1)

      assert response["error"]["code"] == Nodes.error_codes().write_rejected
      assert ExProto.Jog.holder("axes.j1", context.jog) == :none
    end

    test "a Cartesian hold locks every joint under it", context do
      # The whole design, end to end. One held command on `axes` moves six
      # joints, so a second session must not be able to take one of them by
      # naming the joint — it would be commanding a joint the first session is
      # already turning through the tool.
      arm = held_session(:operator, context)

      {:reply, accepted, _} =
        call(
          arm,
          "nodes/call",
          %{
            "nodeId" => "axes.jog_cartesian",
            "arguments" => %{"axis" => "z", "velocity" => 0.05}
          },
          2
        )

      assert accepted["result"]["accepted"] == true
      assert accepted["result"]["deadlineMs"] == ExMo.Schema.Method.watchdog_deadline_ms().default
      assert ExProto.Jog.holder("axes", context.jog) == {:ok, self()}

      joint = held_session(:operator, context)

      response =
        Task.async(fn ->
          {:reply, response, _} = jog(joint, 0.1)
          response
        end)
        |> Task.await()

      assert response["error"]["code"] == Nodes.error_codes().node_held
    end

    test "the Cartesian jog reaches the source with its direction", %{source: source} = context do
      session = held_session(:operator, context)

      {:reply, _, _} =
        call(
          session,
          "nodes/call",
          %{
            "nodeId" => "axes.jog_cartesian",
            "arguments" => %{"axis" => "rz", "velocity" => 0.2}
          },
          2
        )

      assert [{"axes.jog_cartesian", %{"axis" => "rz", "velocity" => 0.2}}] = Static.calls(source)
    end

    test "with no watchdog running, a jog is refused rather than started", context do
      session = held_session(:operator, %{context | jog: :jog_never_started})

      {:reply, response, _} = jog(session, 0.1)

      # Fail closed. Motion nothing is left to stop must not start.
      assert response["error"]["code"] == Nodes.error_codes().write_rejected
    end
  end
end
