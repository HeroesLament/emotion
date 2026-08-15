defmodule ExMo.Projection.JSONRPC.OpenRPC do
  @moduledoc """
  Generates the OpenRPC document describing the controller's JSON-RPC surface.

  The method surface is fixed and small — browse, read, write, subscribe, and a
  handshake. The *nodes* those methods operate on come from the Information
  Model, and are emitted under `x-nodes` rather than being flattened into one
  method per property.

  ## Why the methods are fixed and the nodes are data

  The alternative is generating a method per property: `axes/j1/readPosition`,
  `axes/j1/writeTargetPosition`, and so on. That produces a document that grows
  without bound, changes shape every time an axis is added, and forces a client
  to be regenerated to see a node that already exists.

  Discovering nodes at runtime is what OPC UA does with its address space, for
  the same reason. A client browses, learns what is there and what type it is,
  and renders itself. Adding a seventh axis then changes nothing about the
  protocol — which is the entire point of an admin UI driven by the model.

  ## Why this is generated rather than written

  Because the OPC UA projection is generated from the same model, and two
  hand-maintained descriptions of one machine agree right up until they don't.
  A document under version control that nobody edits is a document that cannot
  drift.

  ## Usage

      mix exmo.openrpc                 # writes protocol/emotion-protocol.openrpc.json
      mix exmo.openrpc --check         # fails if the committed file is stale
  """

  alias ExMo.Schema.Model
  alias ExMo.Projection.JSONRPC

  # The published meta-schema enumerates valid values and tops out here.
  # Documents declaring 1.4.x are rejected by the tooling regardless of what
  # the specification website says.
  @openrpc_version "1.3.2"

  # Date-stamped and compared for equality, not ordered. A controller either
  # speaks a revision or it does not; "newer" is not a question worth asking
  # of a machine that might be older than the client by two firmware releases.
  @protocol_version "2026-08-15"

  @doc "The protocol revision this build speaks."
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  Builds the OpenRPC document for a compiled model.
  """
  @spec document(Model.t()) :: {:ok, map()} | {:error, term()}
  def document(%Model{} = model) do
    with {:ok, table} <- JSONRPC.project(model) do
      {:ok,
       %{
         "openrpc" => @openrpc_version,
         "info" => info(model),
         "servers" => servers(),
         "methods" => methods(),
         "components" => %{
           "schemas" => schemas(),
           "errors" => errors()
         },
         "x-nodeErrors" => node_errors(),
         "x-protocolVersion" => @protocol_version,
         "x-nodes" => nodes_extension(table)
       }}
    end
  end

  @doc "The document as canonical JSON, newline-terminated."
  @spec encode(map()) :: String.t()
  def encode(document) do
    # Sorted keys so regenerating an unchanged model produces a byte-identical
    # file. Without that, `--check` is noise and the diff on every commit is
    # a reshuffle rather than a change.
    document
    |> :json.encode(&json_encoder/2)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp json_encoder(term, encode) when is_map(term) do
    :json.encode_key_value_list(Enum.sort_by(Map.to_list(term), &elem(&1, 0)), encode)
  end

  defp json_encoder(term, encode) when is_atom(term) and not is_boolean(term) and term != nil do
    :json.encode_value(Atom.to_string(term), encode)
  end

  defp json_encoder(term, encode), do: :json.encode_value(term, encode)

  # ── Document sections ─────────────────────────────────────────────────────

  defp info(model) do
    %{
      "title" => "E-Motion Controller Protocol",
      "version" => model.version || "0.0.0",
      "description" => """
      The JSON-RPC surface of an E-Motion controller.

      GENERATED FILE — do not edit. Produced by `mix exmo.openrpc` from the
      ExMo Information Model. Change the model, not this document.

      ## Layering

      RFC 6455 WebSocket carries the bytes and provides liveness through its own
      ping/pong frames, so there is deliberately no application-level heartbeat
      method. JSON-RPC 2.0 provides the envelope, correlation and error codes.
      This document describes the interface.

      ## Nodes are discovered, not declared here

      The methods below are the whole method surface. What they operate on is
      the controller's Information Model, browsed at runtime. `x-nodes` carries
      a snapshot of that model for tooling, but a client should browse rather
      than trust it, because a controller can be configured differently from
      the build that generated this file.

      ## Units

      Every quantity is SI: metres, radians, seconds, and their derivatives.
      There is no unit field on any value. A node's `unit` states what its
      number means; a node's `displayUnit` is a rendering hint for humans and
      never changes the wire.
      """,
      "license" => %{
        "name" => "Apache-2.0",
        "url" => "https://www.apache.org/licenses/LICENSE-2.0"
      }
    }
  end

  defp servers do
    [
      %{
        "name" => "controller",
        "summary" => "A controller on the local network",
        "description" =>
          "Controllers advertise themselves over mDNS as `_emotion._tcp`. " <>
            "The client browses for them rather than asking an operator for an address.",
        "url" => "ws://{host}:{port}/rpc",
        "variables" => %{
          "host" => %{"default" => "emotion.local", "description" => "Controller hostname."},
          "port" => %{"default" => "4000", "description" => "WebSocket port."}
        }
      }
    ]
  end

  # ── Methods ───────────────────────────────────────────────────────────────

  defp methods do
    [
      initialize_method(),
      initialized_notification(),
      browse_method(),
      read_method(),
      write_method(),
      subscribe_method(),
      unsubscribe_method(),
      changed_notification()
    ]
  end

  defp initialize_method do
    %{
      "name" => "initialize",
      "summary" => "Negotiate protocol version and capabilities.",
      "description" => """
      The first message on every connection. No other method may be called
      until this returns and the client has sent `notifications/initialized`.

      The client offers the newest revision it speaks. A controller that speaks
      it echoes it back; one that does not returns the newest it does speak, and
      the client decides whether it can proceed. The controller never guesses.
      """,
      "paramStructure" => "by-name",
      "params" => [
        content("protocolVersion", ref("ProtocolVersion"), true),
        content("clientInfo", ref("PeerInfo"), true),
        content("capabilities", ref("ClientCapabilities"), false)
      ],
      "result" => content("initializeResult", ref("InitializeResult")),
      "errors" => [
        error_ref("UnsupportedProtocolVersion"),
        error_ref("AlreadyInitialized")
      ]
    }
  end

  defp initialized_notification do
    %{
      "name" => "notifications/initialized",
      "summary" => "Client acknowledges the negotiated session.",
      "description" =>
        "Sent as a JSON-RPC notification once the client accepts the result of " <>
          "`initialize`. The controller treats the session as usable from here.",
      "paramStructure" => "by-name",
      "params" => [],
      "result" => content("null", %{"type" => "null"}),
      "x-notification" => true,
      "x-messageDirection" => "clientToServer"
    }
  end

  defp browse_method do
    %{
      "name" => "nodes/browse",
      "summary" => "List the direct children of a node.",
      "description" => """
      Direct children rather than a subtree, because a pendant renders one level
      at a time and a whole-model dump is the thing you least want from a
      controller with a hundred axes.

      Each descriptor carries the node's JSON Schema, so a client learns what a
      value is as it discovers the node, and a generated UI can pick a control
      without knowing anything about robots.

      Omitting `nodeId` browses from the root.
      """,
      "paramStructure" => "by-name",
      "params" => [content("nodeId", %{"type" => "string"}, false)],
      "result" => content("browseResult", ref("BrowseResult")),
      "errors" => [error_ref("NotInitialized"), error_ref("UnknownNode")]
    }
  end

  defp read_method do
    %{
      "name" => "nodes/read",
      "summary" => "Read one or more node values.",
      "description" => """
      Batched, because a pendant rendering twenty properties should cost one
      round trip rather than twenty.

      Results are positional and always the same length as the request. A node
      that cannot be read yields an entry carrying an error rather than
      collapsing the whole batch — one unreadable node among twenty is a
      partial answer, not a failed call.
      """,
      "paramStructure" => "by-name",
      "params" => [
        content("nodeIds", %{"type" => "array", "items" => %{"type" => "string"}}, true)
      ],
      "result" => content("readResult", ref("ReadResult")),
      "errors" => [error_ref("NotInitialized")]
    }
  end

  defp write_method do
    %{
      "name" => "nodes/write",
      "summary" => "Write one or more node values.",
      "description" => """
      Batched like reads, and like reads the results are positional and
      individually fallible.

      Deliberately NOT atomic. A batch that half-succeeds reports exactly which
      halves, because the alternative — rolling back a write that has already
      reached a drive — is not something this layer can honestly offer.
      """,
      "paramStructure" => "by-name",
      "params" => [
        content("writes", %{"type" => "array", "items" => ref("WriteRequest")}, true)
      ],
      "result" => content("writeResult", ref("WriteResult")),
      "errors" => [error_ref("NotInitialized")]
    }
  end

  defp subscribe_method do
    %{
      "name" => "nodes/subscribe",
      "summary" => "Subscribe to changes on observable nodes.",
      "description" => """
      Only nodes whose descriptor reports `observable` may be subscribed to;
      anything else is refused rather than silently never delivered.

      The requested rate is advisory. The controller returns what it will
      actually send at, which may be lower, and clients must read the granted
      rate rather than assuming they got what they asked for.

      **Updates are conflated, never queued.** A client slower than the stream
      receives the newest value and misses the ones between, by design — the
      sequence number skips and that is normal. An implementation that buffers
      updates turns a momentarily slow client into one that falls permanently
      behind, which is worse in every way than dropping a frame.
      """,
      "paramStructure" => "by-name",
      "params" => [
        content("nodeIds", %{"type" => "array", "items" => %{"type" => "string"}}, true),
        content(
          "rateHz",
          %{"type" => "number", "exclusiveMinimum" => 0, "maximum" => 1000, "default" => 30},
          false
        )
      ],
      "result" => content("subscription", ref("Subscription")),
      "errors" => [
        error_ref("NotInitialized"),
        error_ref("UnknownNode"),
        error_ref("NotObservable"),
        error_ref("TooManySubscriptions"),
        # Top-level here, unlike read and write. A subscription is one ongoing
        # thing: there is no partial subscription to half a node list, so a
        # caller lacking the grant for any node in the request is refused the
        # whole call rather than given a subscription that silently omits it.
        error_ref("Forbidden")
      ]
    }
  end

  defp unsubscribe_method do
    %{
      "name" => "nodes/unsubscribe",
      "summary" => "End a subscription.",
      "description" =>
        "Idempotent. Ending an unknown or already-ended subscription succeeds, " <>
          "because a client tearing down after a reconnect should not have to " <>
          "reason about whether the controller already dropped it.",
      "paramStructure" => "by-name",
      "params" => [content("subscriptionId", %{"type" => "string"}, true)],
      "result" => content("ok", %{"type" => "object", "additionalProperties" => false}),
      "errors" => [error_ref("NotInitialized")]
    }
  end

  defp changed_notification do
    %{
      "name" => "notifications/nodes/changed",
      "summary" => "A conflated batch of node values.",
      "description" => """
      Carries the newest value of each changed node in one subscription. `seq`
      is monotonic per subscription and **skips** — a gap means values were
      conflated away, which is expected and must not be treated as an error or
      trigger a resync.

      Batched per tick rather than one notification per node, so a six-axis
      update is one frame.
      """,
      "paramStructure" => "by-name",
      "params" => [
        content("subscriptionId", %{"type" => "string"}, true),
        content("seq", %{"type" => "integer", "minimum" => 0}, true),
        content("timestamp", ref("Timestamp"), true),
        content("values", %{"type" => "array", "items" => ref("NodeValue")}, true)
      ],
      "result" => content("null", %{"type" => "null"}),
      "x-notification" => true,
      "x-messageDirection" => "serverToClient"
    }
  end

  # ── Component schemas ─────────────────────────────────────────────────────

  defp schemas do
    %{
      "ProtocolVersion" => %{
        "type" => "string",
        "pattern" => "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
        "description" =>
          "Date-stamped protocol revision. Compared for equality, not ordered.",
        "examples" => [@protocol_version]
      },
      "Timestamp" => %{
        "type" => "string",
        "format" => "date-time",
        "description" =>
          "RFC 3339 with at least millisecond precision, from the controller's " <>
            "clock. Use it for ordering and intervals; only trust it for absolute " <>
            "correlation when the controller reports a PTP-disciplined time base."
      },
      "PeerInfo" => %{
        "type" => "object",
        "required" => ["name", "version"],
        "properties" => %{
          "name" => %{"type" => "string"},
          "version" => %{"type" => "string"}
        }
      },
      "ClientCapabilities" => %{
        "type" => "object",
        "description" =>
          "Presence of a key means the client supports the feature. Empty objects " <>
            "are deliberate: they leave room for per-feature options without a " <>
            "breaking change.",
        "properties" => %{
          "subscriptions" => %{"type" => "object"},
          "batching" => %{"type" => "object"}
        }
      },
      "ServerCapabilities" => %{
        "type" => "object",
        "properties" => %{
          "nodes" => %{
            "type" => "object",
            "properties" => %{
              "count" => %{"type" => "integer"},
              "maxRateHz" => %{"type" => "number"},
              "maxSubscriptions" => %{"type" => "integer"}
            }
          },
          "timeBase" => %{
            "type" => "string",
            "enum" => ["local", "ptp"],
            "description" =>
              "`ptp` means timestamps from this controller are comparable with " <>
                "those from any other controller on the same time base. `local` " <>
                "means they are not, and a client must not overlay them."
          }
        }
      },
      "InitializeResult" => %{
        "type" => "object",
        "required" => ["protocolVersion", "serverInfo", "capabilities"],
        "properties" => %{
          "protocolVersion" => ref("ProtocolVersion"),
          "serverInfo" => ref("PeerInfo"),
          "capabilities" => ref("ServerCapabilities")
        }
      },
      "NodeDescriptor" => %{
        "type" => "object",
        "required" => ["nodeId", "name", "class"],
        "description" => "What a browse returns for one node.",
        "properties" => %{
          "nodeId" => %{"type" => "string", "description" => "Dotted path, e.g. `axes.j1.position`."},
          "name" => %{"type" => "string"},
          "class" => %{"type" => "string", "enum" => ["object", "property", "method"]},
          "description" => %{"type" => "string"},
          "hasChildren" => %{"type" => "boolean"},
          "schema" => %{
            "type" => "object",
            "description" => "JSON Schema for this node's value. Absent for objects."
          },
          "unit" => %{
            "type" => "string",
            "description" => "SI unit of the value, e.g. `rad`. Absent when dimensionless."
          },
          "displayUnit" => %{
            "type" => "string",
            "description" =>
              "Rendering hint for humans, e.g. `degrees`. Never affects the value."
          },
          "readable" => %{"type" => "boolean"},
          "writable" => %{"type" => "boolean"},
          "observable" => %{"type" => "boolean"}
        }
      },
      "BrowseResult" => %{
        "type" => "object",
        "required" => ["node", "children"],
        "properties" => %{
          "node" => ref("NodeDescriptor"),
          "children" => %{"type" => "array", "items" => ref("NodeDescriptor")}
        }
      },
      "NodeValue" => %{
        "type" => "object",
        "required" => ["nodeId"],
        "properties" => %{
          "nodeId" => %{"type" => "string"},
          "value" => %{"description" => "Type per the node's own schema."},
          "timestamp" => ref("Timestamp"),
          "error" => ref("NodeError")
        }
      },
      "NodeError" => %{
        "type" => "object",
        "required" => ["code", "message"],
        "description" =>
          "A per-node failure inside an otherwise successful batch. Uses the same " <>
            "codes as the top-level errors.",
        "properties" => %{
          "code" => %{"type" => "integer"},
          "message" => %{"type" => "string"}
        }
      },
      "ReadResult" => %{
        "type" => "object",
        "required" => ["values"],
        "properties" => %{
          "values" => %{"type" => "array", "items" => ref("NodeValue")}
        }
      },
      "WriteRequest" => %{
        "type" => "object",
        "required" => ["nodeId", "value"],
        "properties" => %{
          "nodeId" => %{"type" => "string"},
          "value" => %{"description" => "Type per the node's own schema."}
        }
      },
      "WriteResult" => %{
        "type" => "object",
        "required" => ["results"],
        "properties" => %{
          "results" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["nodeId", "ok"],
              "properties" => %{
                "nodeId" => %{"type" => "string"},
                "ok" => %{"type" => "boolean"},
                "error" => ref("NodeError")
              }
            }
          }
        }
      },
      "Subscription" => %{
        "type" => "object",
        "required" => ["subscriptionId", "nodeIds", "rateHz"],
        "properties" => %{
          "subscriptionId" => %{"type" => "string"},
          "nodeIds" => %{"type" => "array", "items" => %{"type" => "string"}},
          "rateHz" => %{
            "type" => "number",
            "description" => "The rate the controller will actually send at."
          }
        }
      }
    }
  end

  # ── Error codes ───────────────────────────────────────────────────────────

  defp errors do
    %{
      "NotInitialized" => %{
        "code" => -32000,
        "message" => "Session not initialized; call initialize first."
      },
      "AlreadyInitialized" => %{
        "code" => -32001,
        "message" => "Session already initialized on this connection."
      },
      "UnsupportedProtocolVersion" => %{
        "code" => -32002,
        "message" => "No mutually supported protocol version.",
        "data" => %{"supported" => [@protocol_version]}
      },
      "UnknownNode" => %{"code" => -32003, "message" => "No such node."},
      "NotReadable" => %{"code" => -32004, "message" => "Node is not readable."},
      "NotWritable" => %{"code" => -32005, "message" => "Node is not writable."},
      "NotObservable" => %{
        "code" => -32006,
        "message" => "Node is not observable and cannot be subscribed to."
      },
      "InvalidValue" => %{
        "code" => -32007,
        "message" => "Value does not satisfy the node's schema."
      },
      "TooManySubscriptions" => %{
        "code" => -32008,
        "message" => "Subscription limit reached for this connection."
      },
      "WriteRejected" => %{
        "code" => -32010,
        "message" => "The controller refused the write in its current state."
      },
      # -32009 is skipped deliberately. It briefly belonged to
      # UnknownSubscription, which was deleted once unsubscribe became
      # idempotent and nothing could return it. Reusing a retired code is how a
      # client that pinned an old document renders the wrong message.
      "Forbidden" => %{
        "code" => -32011,
        "message" => "The authenticated principal does not hold the required grant.",
        "data" => %{"requiredGrant" => "the grant that was missing"}
      }
    }
  end

  # Codes that appear inside a `NodeError` within a batch result rather than as
  # a top-level JSON-RPC error.
  #
  # Batched reads and writes are individually fallible on purpose: one
  # unreadable node among twenty is a partial answer, not a failed call. That
  # means these codes are never returned by the method itself, and a document
  # that listed them under `errors` would be describing something that cannot
  # happen. Listing them here says the true thing instead.
  defp node_errors do
    %{
      "description" =>
        "Codes that can appear in a NodeError inside a batch result, rather " <>
          "than as a top-level JSON-RPC error.",
      "codes" => [
        "UnknownNode",
        "NotReadable",
        "NotWritable",
        "InvalidValue",
        "WriteRejected",
        # Per-node, because authorisation is per-node: a batch may read fifteen
        # properties the caller is entitled to and one it is not, and the answer
        # to that is fifteen values and one refusal.
        "Forbidden"
      ]
    }
  end

  # ── The model snapshot ────────────────────────────────────────────────────

  # A snapshot for tooling and review, deliberately not the source of truth. A
  # client browses, because a controller can be configured differently from the
  # build that generated this file, and a stale list that looks authoritative is
  # worse than no list.
  defp nodes_extension(table) do
    %{
      "description" =>
        "Snapshot of the Information Model at generation time. Informative only " <>
          "— browse the live controller rather than trusting this.",
      "root" => table.root,
      "nodes" =>
        Map.new(table.nodes, fn {id, node} ->
          {id, node_summary(node)}
        end)
    }
  end

  defp node_summary(%{class: :object} = node) do
    drop_nils(%{
      "class" => "object",
      "name" => node.name,
      "description" => node.description,
      "children" => node.children
    })
  end

  defp node_summary(%{class: :property} = node) do
    drop_nils(%{
      "class" => "property",
      "name" => node.name,
      "description" => node.description,
      "schema" => node.schema,
      "unit" => node.unit,
      "displayUnit" => stringify(node.display_unit),
      "readable" => node.readable,
      "writable" => node.writable,
      "observable" => node.observable
    })
  end

  defp node_summary(%{class: :method} = node) do
    drop_nils(%{
      "class" => "method",
      "name" => node.name,
      "description" => node.description,
      "async" => node.async
    })
  end

  # The display hint arrives as an atom from the schema. A document that is
  # only JSON-shaped once encoded is a document whose tests and whose output
  # disagree, so it becomes a string here rather than in the encoder.
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value

  defp drop_nils(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp content(name, schema), do: %{"name" => name, "schema" => schema}

  defp content(name, schema, required) do
    %{"name" => name, "required" => required, "schema" => schema}
  end

  defp ref(name), do: %{"$ref" => "#/components/schemas/#{name}"}
  defp error_ref(name), do: %{"$ref" => "#/components/errors/#{name}"}
end
