# ros2_ex

**Status:** design. Nothing in this document is implemented.
**Scope:** a native ROS 2 client library for Elixir, built as a Rustler wrapper
over [RustDDS](https://github.com/jhelovuo/RustDDS).

For how E-Motion consumes this library to present itself as a `controller_manager`,
see [ROS2_INTEGRATION.md](ROS2_INTEGRATION.md). This document does not mention
E-Motion again after the next section, and that is deliberate.

---

## The gap

There is exactly one way to talk to a ROS 2 graph from the BEAM today, and it is
`rclex` — a NIF over `rcl`. It is maintained, Nerves-aware, and it works, and it
means a full ROS 2 client stack has to exist on the target. For a Nerves device
that is a firmware image carrying `rcl`, `rmw`, a DDS implementation, and their
transitive dependencies, to run an Elixir program.

`ros2_ex` exists to remove that. **No `rcl`. No `rmw`. No `ament`. No ROS 2
installation on the device.** An Elixir application that is a first-class node on
a ROS 2 graph — visible in `ros2 node list`, its topics legible to
`ros2 topic info -v`, reachable by `ros2 service call` — with nothing on the
target but the BEAM and one Rust NIF.

Second differentiator: **services and actions as first-class citizens.** Pub/sub
is the easy half and it is where most non-C++ client libraries stop. An action
server is what makes a robot drivable by MoveIt, and it is the thing a motion
controller most needs to expose.

### Who this is for

Anyone running Elixir or Nerves on a machine that has to be visible to a ROS 2
system: motion controllers, sensor gateways, fleet coordinators, HMIs, test rigs.
The first consumer is E-Motion, and E-Motion drives every requirement in v0.1 — that is
a feature, not a caveat. A middleware library with no consumer has no forcing
function to be correct and no reason for anyone to maintain it.

---

## Why RustDDS, and why not `ros2-client`

`ros2-client` is a complete ROS 2 client in Rust built on RustDDS. Wrapping it
would be less work. It is the wrong seam.

RustDDS is a **DDS** library: participants, topics, readers, writers, QoS,
discovery. `ros2-client` is the **ROS 2** layer on top: name mangling, the node
graph, service RPC, actions, parameters, rosout, ROS time. If we wrap
`ros2-client`, all of that lives in Rust and `ros2_ex` becomes an FFI shim — a
few thousand lines of term marshalling around someone else's design. The library
would work, and it would not be an Elixir library in any sense that matters. An
action server would be a Rust action server with an Elixir callback bolted to it,
not `handle_goal/2` on a supervised process.

It also directly contradicts the layering rule this project already committed to:
*everything above the transport is pure Elixir*. Wrapping `ros2-client` moves the
boundary up above services and actions, and the rule becomes decorative.

So the boundary sits at **DDS entities**. Rust does RTPS — discovery, reliable
writers, heartbeats, ACKNACKs, fragmentation, the parts nobody should write
twice. Elixir does everything ROS-shaped, and everything ROS-shaped is the
library.

**The bill for that choice.** `ros2-client` is ~8,300 LOC excluding its codegen
tool. Reimplementing the ROS 2 layer in Elixir is roughly:

| Subsystem | ros2-client LOC | Elixir assessment |
|---|---|---|
| Node, pub/sub plumbing | 2,240 | Shrinks a lot — GenServers replace generic ceremony |
| Actions | 1,439 | **Real work.** Pure ROS composition over services; no DDS involvement |
| ROS time / clock | 1,154 | Shrinks a lot — `System.monotonic_time`, plus `/clock` sim time |
| Service RPC | 1,090 | **Real work**, and the part to port most carefully |
| Parameters | 484 | Mechanical |
| Name mangling | 474 | Easy, pure string logic, satisfying to port |
| Context / participant mgmt | 447 | Mostly absorbed by the NIF layer |
| `ros_discovery_info` + `Gid` | 264 | Small but load-bearing — this is what makes `ros2 node list` work |
| rosout | 232 | Trivial with `Logger` |

Call it 3–4 kLOC of Elixir once the shrinkage is accounted for, concentrated in
services and actions. That is the price, and it buys a library whose interesting
half is written in the language its users write.

`ros2-client` remains the reference implementation. Read it constantly. Two files
in particular are near-verbatim ports rather than fresh design: `names.rs` for
mangling, and `service/wrappers.rs` for the passthrough adapters and the
request/reply correlation quirks.

### Viability, verified

The two load-bearing questions were checked by compiling and running a test
program against `rustdds` 0.14.1, not by reading documentation.

- **Raw CDR bytes pass through both directions.** Twelve bytes of hand-rolled CDR
  written and taken back byte-identical, with the encapsulation identifier
  reported out-of-band as `CDR_LE`.
- **Service RPC correlation travels on the wire.** A write carrying
  `related_sample_identity` was observed at the reader with the sequence number
  intact, so it genuinely rides as RTPS inline QoS rather than being a
  local-only field.

One gap was found and it is real. See *Type hashes* below.

---

## Architecture

```
ros2_ex/
  native/ros2_dds/          # the Rust NIF crate — thin, and stays thin
    src/lib.rs              # rustler entrypoints
    src/adapter.rs          # passthrough Serializer/DeserializerAdapter over Bytes
    src/participant.rs      # ResourceArc wrappers, stream-driving thread
  lib/ros2/
    cdr/
      encoder.ex            # XCDR1 body — no encapsulation header, see below
      decoder.ex
    idl/
      parser.ex             # .msg / .srv / .action
      generator.ex          # -> Elixir structs + encode/1 + decode/1
      type_hash.ex
    names.ex                # rt/ rq/ rr/ mangling, node and topic name rules
    qos.ex
    node.ex
    publisher.ex
    subscription.ex
    service/
      server.ex
      client.ex
      mapping.ex            # Basic | Enhanced | Cyclone correlation
    action/
      server.ex
      client.ex
      goal.ex               # one gen_statem per in-flight goal
    graph.ex                # ros_discovery_info, ParticipantEntitiesInfo, Gid
    parameters.ex
    clock.ex
    rosout.ex
    dds.ex                  # the NIF boundary, and the only module that knows it exists
  lib/mix/tasks/
    ros2.gen.ex
```

The rule that makes this work: **`ros2.dds` is the only Elixir module that
references the NIF.** Everything else is pure. That means CDR, naming, service
correlation, action decomposition, parameters, and the graph can all be tested
with no network, no ROS 2, and — for most of them — no Rust build.

### The NIF boundary

Signatures below are from RustDDS 0.14.1 and are the ones the wrapper depends on.

**Entities.** `DomainParticipant::new(domain_id)`, `create_publisher(&QosPolicies)`,
`create_subscriber(&QosPolicies)`, `create_topic(name, type_desc, qos, TopicKind)`.
Use the **`no_key`** variants throughout — RustDDS's own documentation notes that
ROS 2 has no concept of keyed topics, and `ros2-client` uses `no_key` for topics,
services, and actions alike. Correlation rides on write options, not on keys.

**Payloads.** A passthrough `SerializerAdapter` / `DeserializerAdapter` pair over
`Bytes`:

```rust
fn to_bytes(value: &RawPayload) -> Result<Bytes, E>   // O(1), Bytes is refcounted
fn decode_bytes(self, input: &[u8], encoding: RepresentationIdentifier) -> Result<..>
```

`ros2-client`'s `service/wrappers.rs` contains a working template — its own
comment describes the adapters as "essentially pass-through, and do no actual
serialization." Port it.

**Correlation.**

```rust
DataWriter::write_with_options(&self, data, WriteOptions) -> WriteResult<SampleIdentity, D>
WriteOptionsBuilder::related_sample_identity(SampleIdentity) -> Self
WriteOptionsBuilder::to_single_reader(GUID) -> Self          // reply only to the requester
SampleInfo::sample_identity(&self) -> SampleIdentity
SampleInfo::related_sample_identity(&self) -> Option<SampleIdentity>
SampleInfo::writer_guid(&self) -> GUID
```

`SampleIdentity` is `{ writer_guid: GUID, sequence_number: SequenceNumber }`.
These cross the NIF as a `{guid_binary, integer}` tuple.

**Discovery.** `discovered_topics()`, `discovered_readers()`, `discovered_writers()`
for pull, and `status_listener()` for push — `DomainParticipantStatusEvent` covers
`ParticipantDiscovered`, `ParticipantLost { reason }`, `TopicDetected`,
`ReaderDetected`, `WriterDetected`, `RemoteReaderMatched`,
`RemoteReaderQosIncompatible { requested_qos, offered_qos }`, and siblings.

**Delivery.** Use the `futures::Stream` path — `async_sample_stream()`,
`SimpleDataReader::as_async_stream()`, and the participant status stream. One OS
thread per participant runs an executor selecting across those streams and calls
`OwnedEnv::send_and_clear` to deliver `{:ros2_message, ref, binary, info}` into
the owning Elixir process.

Do **not** use the mio paths. RustDDS's `Evented` (mio 0.6) and `event::Source`
(mio 0.8, non-default feature) impls on `DataReader` are marked `WARNING! UNTESTED`
in the source. The async streams are what `ros2-client` itself drives `Node::spin`
with.

**Handle ownership.** `DomainParticipant`, `Publisher`, `Subscriber`, `Topic`,
`DataWriter`, and `DataReader` are all `Send + Sync + Clone` — verified by
compile-time assertion — so `ResourceArc` works throughout. Two asymmetries
matter:

- `DataWriter` methods take `&self`. `ResourceArc<DataWriter<..>>` is directly
  callable from a NIF.
- `DataReader::take/read` take `&mut self`. Rather than wrapping in a mutex,
  **move readers into the stream thread at creation and never expose them to NIF
  calls at all.** Reads become messages, which is what we want anyway.

---

## Serialization

**XCDR1, always.** ROS 2 pins `CdrVersion::XCDRv1` throughout `rmw_fastrtps`. No
XCDR2, no `DHEADER`/`EMHEADER`, no mutable or appendable extensibility. User types
are plain final structs. Write that into the decoder as an assertion, not a
comment.

**Elixir emits the CDR body only — no encapsulation header.** This is a
correction worth stating loudly, because it is the opposite of what a from-scratch
implementation would do. RustDDS models a payload as
`SerializedPayload { representation_identifier, representation_options, value }`
and keeps the 4-byte header *out of* `value`. So the passthrough adapter receives
the body, and the representation identifier crosses the NIF as a separate term
(`:cdr_le` / `:cdr_be`). If Elixir emits `00 01 00 00` at the front, it will be
double-headered on the wire and every consumer will see garbage.

Alignment is still measured from the start of the body, which is now also the
start of the buffer Elixir produces — so the classic off-by-four bug is
structurally impossible in this design. That is a small gift and worth noting in
the encoder's moduledoc so nobody "fixes" it later.

The remaining rules:

- Each primitive aligns to `min(sizeof(T), 8)` from the start of the body.
- `string` is a `uint32` length **including the NUL terminator**, then bytes,
  then `\0`. Empty is `01 00 00 00 00`.
- `sequence<T>` is a `uint32` **element** count, then elements each aligned per
  their own type. Empty is four zero bytes.
- Fixed arrays `T[N]` have no length prefix.
- Nested structs inline; alignment does **not** reset at the boundary.
- `wstring` is out of scope. ROS 2's handling is nonstandard relative to CDR and
  has diverged between RMW implementations; no message worth supporting uses one.

The codec is a few hundred lines of binary pattern matching. Elixir is unusually
good at this. The work is the generator.

Fixture-based testing is not optional: capture real serialized payloads from a
ROS 2 publisher, commit them, round-trip against them. Property tests catch
self-consistency, which is exactly the bug class that does not matter.

## Type hashes — and the one real gap

`RIHS01_<64 hex>` is SHA-256 over a canonical, whitespace-free JSON serialization
of the type description per REP-2016. **Extract, do not compute** — reproducing
that emitter byte-for-byte is a correctness trap with no payoff. Pull hashes from
an installed ROS 2 at generation time and bake them into generated modules as
constants.

Then the gap. **RustDDS cannot publish USER_DATA QoS**, and USER_DATA is where
ROS 2 puts the type hash.

The asymmetry is precise:

- **Reading remote USER_DATA works.** `DiscoveredReaderData` and
  `DiscoveredWriterData` both expose `user_data: Vec<u8>`, parsed from
  `PID_USER_DATA`.
- **Writing our own does not.** `QosPolicies` has no `user_data` field at all —
  the `UserData` variant is commented out of `QosPolicyId`, and locally-created
  endpoints hardcode `user_data: Vec::new()`, which the PL-CDR serializer then
  discards. It is never emitted.
- **Participant-level USER_DATA is not modelled**, so the ROS 2 enclave field has
  nowhere to go either.

`ros2-client` has the same gap — it contains no reference to type hashes,
USER_DATA, or enclaves anywhere. So this is a property of the whole Rust DDS
stack, not something wrapping `ros2-client` would have avoided.

**What it costs, in practice: almost nothing, on DDS.** USER_DATA does not
participate in DDS endpoint matching. Our endpoints will show
`RIHS01_000…0` in `ros2 topic info -v` and everything else works. It is
cosmetic today.

**What it costs later: the zenoh door.** Under `rmw_zenoh` the type hash is a
*segment of the key expression*, so a missing hash is a different key, which is
silent total non-communication with no fallback. Any future zenoh transport
requires this fixed first.

**The fix is small and upstream.** The parse side already exists; adding
`UserData` to `QosPolicies` plus the two emit sites is on the order of sixty
lines. The maintainer is demonstrably active — 2,044 commits, dozens in the last
two months. Budget one upstream PR, plan to vendor a patched build in the interim,
and ship v0.1 without type hashes rather than blocking on it.

This decision should be made explicitly before implementation starts, because it
is the only item in the design that is not already solved.

## Service RPC

Three correlation conventions exist and ROS 2 calls them `ServiceMapping`:

- **Enhanced** (Fast DDS) — correlation via inline QoS `related_sample_identity`,
  no in-payload header. This is what `write_with_options` gives us.
- **Basic** and **Cyclone** — a header prepended to the CDR payload.

`ros2_ex` should implement Enhanced first and structure `ROS2.Service.Mapping` so
the others can follow, because the choice depends on which RMW the other side is
running and is not ours to make.

Port `ros2-client`'s FastDDS workaround verbatim: Fast DDS sometimes sends
`SEQUENCENUMBER_UNKNOWN` in `related_sample_identity`, and the correct response
is to patch it with the request's own sample identity. This is the kind of quirk
that costs a week to rediscover.

`to_single_reader(GUID)` is worth using for replies — it addresses the response
to the requesting participant instead of fanning it across everyone subscribed to
the reply topic.

## The graph

DDS discovery gives us endpoints, not ROS nodes. `ros2 topic info -v` works off
`discovered_readers()` / `discovered_writers()`; `ros2 node list` does not, because
DDS has no concept of a node.

Nodes come from the `ros_discovery_info` topic, carrying
`ParticipantEntitiesInfo { gid, node_entities_info_seq }`. This is ~264 LOC in
`ros2-client` and it is the difference between "an endpoint appears" and "a node
appears." Implement it in `ROS2.Graph`.

Two traps: `Gid` is **16 bytes for Iron and later, 24 for Galactic and Humble** —
a distro conditional in the wire format itself. And `discovered_topics()` returns
duplicate entries for a single topic; dedupe by name.

## QoS

Ship the canonical profiles from `rmw/qos_profiles.h` verbatim: `default`
(reliable, volatile, KeepLast 10), `sensor_data` (best-effort, depth 5),
`services_default`, `parameters`, `parameter_events` (depth 1000),
`rosout_default` (reliable, **transient_local**, depth 1000, 10 s lifespan),
`system_default`.

RustDDS's `QosPolicyBuilder` covers durability, presentation, deadline, latency
budget, ownership, liveliness, time-based filter, reliability, destination order,
history, resource limits, and lifespan. Everything the profiles need — except
USER_DATA, above.

A publisher matches a subscription only if offered ≥ requested on every policy.
RELIABLE publisher against a BEST_EFFORT subscriber is fine; the reverse is not.
TRANSIENT_LOCAL publisher against a VOLATILE subscriber is fine; the reverse is
not. Deadline and liveliness participate; history depth does not — it is a local
resource policy.

**The failure mode is silence.** No error, no log, no connection. `ros2 topic
echo` prints nothing forever and the user has no thread to pull.

RustDDS hands us everything needed to fix that, and we should use all of it from
the first release. `DataReaderStatus::RequestedIncompatibleQos` and
`DataWriterStatus::OfferedIncompatibleQos` both carry the offending
`QosPolicyId` **and the full requested and offered `QosPolicies`**, and the
participant status stream carries `RemoteReaderQosIncompatible` /
`RemoteWriterQosIncompatible` with the same detail. Surface them as
`Logger.warning` naming the topic, the policy, and both sides.

Without this, the first bug report from every single user will be this, and none
of them will be able to describe it.

Latching is the other half of the same trap. `robot_description` and `/tf_static`
are transient_local, and a volatile subscriber against them connects successfully
and receives nothing, because everything it wanted was published before it
started. "My TF tree is empty" is the most common ROS 2 support question in
existence and this is why.

## Wire naming

Topics are `rt/<name>`. Services are `rq/<name>Request` and `rr/<name>Reply` —
suffix concatenated with no separator. Type names mangle to
`pkg::msg::dds_::TypeName_`, and correspondingly `::srv::dds_::Foo_Request_` and
`::action::dds_::Foo_SendGoal_Request_`.

An action `<A>` decomposes into exactly three services and two topics:

| Kind | Name | Type |
|---|---|---|
| Service | `<A>/_action/send_goal` | `<T>_SendGoal` |
| Service | `<A>/_action/cancel_goal` | `action_msgs/srv/CancelGoal` |
| Service | `<A>/_action/get_result` | `<T>_GetResult` |
| Topic | `<A>/_action/feedback` | `<T>_FeedbackMessage` |
| Topic | `<A>/_action/status` | `action_msgs/msg/GoalStatusArray` |

Actions are therefore pure ROS composition over services with no DDS involvement
— a clean Elixir layer, and the largest single piece of new work.

The prefixes are specified in the ROS 2 design articles, but the `Request`/`Reply`
suffix and the `dds_` type mangling are `rmw_fastrtps` implementation details
sourced from its source rather than a specification. Cyclone differs in places.
Do not claim cross-RMW compatibility without testing against both.

---

## The API

Sketch, not a specification. The shape matters more than the details.

```elixir
{:ok, node} = ROS2.Node.start_link(name: "controller_manager", namespace: "/")

{:ok, pub} = ROS2.Publisher.start_link(
  node: node,
  topic: "/joint_states",
  type: SensorMsgs.Msg.JointState,
  qos: ROS2.QoS.default()
)

ROS2.Publisher.publish(pub, %SensorMsgs.Msg.JointState{
  header: ROS2.Clock.header("base_link"),
  name: ["joint_1", "joint_2"],
  position: [0.0, -0.5],
  velocity: [0.0, 0.0],
  effort: []
})

{:ok, _sub} = ROS2.Subscription.start_link(
  node: node,
  topic: "/robot_description",
  type: StdMsgs.Msg.String,
  qos: ROS2.QoS.transient_local(1),
  to: self()
)
```

A service server is a behaviour, because that is what it is:

```elixir
defmodule MyRobot.SwitchController do
  use ROS2.Service.Server, type: ControllerManagerMsgs.Srv.SwitchController

  @impl true
  def handle_request(%{activate_controllers: activate,
                       deactivate_controllers: deactivate,
                       strictness: strictness}, _ctx) do
    case MyRobot.Controllers.switch(activate, deactivate, strictness) do
      :ok              -> {:reply, %{ok: true,  message: ""}}
      {:error, reason} -> {:reply, %{ok: false, message: to_string(reason)}}
    end
  end
end
```

An action server is the interesting one:

```elixir
defmodule MyRobot.FollowJointTrajectory do
  use ROS2.Action.Server, type: ControlMsgs.Action.FollowJointTrajectory

  @impl true
  def handle_goal(goal, _ctx) do
    if valid_joints?(goal.trajectory.joint_names), do: :accept, else: {:reject, :invalid_joints}
  end

  @impl true
  def handle_cancel(_handle), do: :accept

  @impl true
  def handle_execute(goal, handle) do
    ROS2.Action.Server.feedback(handle, %{desired: d, actual: a, error: e, index: i})

    case run(goal) do
      :ok -> {:succeed, %{error_code: 0, error_string: ""}}
      {:error, :path_tolerance} -> {:abort, %{error_code: -4, error_string: "path tolerance"}}
    end
  end
end
```

Under the hood the server owns the three services, the two topics, and one
`gen_statem` per in-flight goal tracking `GoalStatus` transitions. None of that is
visible to the callback module, and that is the entire value of the abstraction.

### Code generation

```
mix ros2.gen sensor_msgs trajectory_msgs control_msgs controller_manager_msgs \
    --out lib/my_robot/ros2_msgs
```

Emits Elixir modules with `defstruct`, `encode/1`, `decode/1`, the mangled DDS
type name, and the RIHS01 hash as a module attribute (unused on the wire until
the USER_DATA gap is closed, but generated now so it is there when it is).
**Output is committed into the consuming application**, not shipped as packages
from here.

`rclex` tried the two-package split (`rclex` + `rclex_gen_msgs`); the codegen
package went stale in 2022 and generation folded back in. Shipping pregenerated
message packages per ROS package is the part that does not scale — there are
hundreds, they version independently, and none of them are our business. A Mix
task generating into the consumer is how the protobuf and gRPC libraries solve
the same problem.

Requiring a ROS 2 installation on the *developer's* machine to run `mix ros2.gen`
is fine. Requiring one on the target is the thing this library exists to avoid.

---

## Rust-side hazards

Four things that will bite, all cheap to handle up front.

**Pin the version exactly.** `rustdds = "=0.14.1"`. 0.13 → 0.14 was a breaking
minor and there is no stability guarantee. 0.14.1 exists specifically to
re-export `rustdds::mio` and `rustdds::bytes` because they appear in the API —
**use those re-exports**, not our own `bytes`/`mio` dependencies, or the types
will not unify.

**MSRV is 1.88.0** and it moves — 0.13.1 was 1.85.1. This is a Nerves
cross-compilation constraint, not just a developer-machine one.

**`Drop` joins background threads.** A participant spawns two named OS threads
(discovery, event loop) and dropping it sends a stop command and joins them.
Never let that happen on a normal scheduler; do teardown on a dirty-IO NIF or
handle it in the resource destructor with that in mind.

**RustDDS panics on poisoned internal mutexes** — the repo carries a
`PANIC_HARDENING_TODO.md`. A panic on our own stream thread is survivable; a
panic inside a NIF call brings down the VM. Wrap every NIF entry point in
`catch_unwind`.

---

## Scope

**v0.1 — "a robot you can drive."** The exact set of primitives a
`controller_manager` implementation needs:

- CDR encoder/decoder (headerless body), IDL parser, `mix ros2.gen`
- The Rust NIF crate: participant, topic, passthrough adapters, writer/reader
  resources, stream thread, status events
- Node, Publisher, Subscription
- Service server and client, Enhanced mapping
- **Action server** with the full wire decomposition and per-goal `gen_statem`
- Parameters: the six `rcl_interfaces` services plus `/parameter_events`
- `ROS2.Graph` — `ros_discovery_info` so `ros2 node list` works
- QoS profiles and loud incompatibility diagnostics
- `/rosout`

**v0.2** — action client, Basic and Cyclone service mappings, `/tf` and
`/tf_static` helpers, ROS time and sim time via `/clock`, lifecycle node support.

**v0.3 and beyond** — the USER_DATA upstream PR and real type hashes; a zenoh
transport, which requires it.

**Explicit non-goals** — SROS2 and DDS security, XCDR2, `wstring`, intra-process
transport, `ros2 bag` writing, dynamic type description services. And no ROS 2
build-system integration: no `colcon`, no `ament`, no `package.xml`. ROSiE built
`colcon-rebar3` and `rosie_ros2_deps` to bridge into the ROS 2 build world, and
that is a large surface with a small payoff for a project that already has Mix.

---

## Milestones

**M0 — codec, codegen, naming. No Rust.** CDR round-tripping against committed
fixtures captured from a real ROS 2 publisher. IDL parser and generator. Name
mangling ported from `names.rs`. Type hashes extracted. This is most of the
library's value and it needs no network, no NIF, and no ROS 2 on the test
machine. Finish it and get it green before any Rust exists.

**M1 — the NIF, and one topic.** Passthrough adapters, participant and writer
resources, the stream thread, `OwnedEnv::send_and_clear` delivery. Success is
`ros2 topic echo` on another machine receiving a well-formed message.

**M2 — the graph.** `ros_discovery_info`, `ParticipantEntitiesInfo`, `Gid`, plus
discovery pull and the status stream wired to diagnostics. Success is the node
appearing in `ros2 node list` and `ros2 topic info -v` showing correct QoS.

**M3 — services.** Server and client over `write_with_options` correlation, then
the six parameter services. Success is `ros2 param list` and `ros2 service call`
working against an Elixir node.

**M4 — actions.** Server, goal state machine, cancellation, feedback. Success is
a `ros2 action send_goal --feedback` round trip.

**M5 — publish.** Hex package, precompiled NIFs, docs, the honest README below.

Note M2 moved ahead of services relative to the previous plan. The graph is what
makes everything else debuggable — without `ros2 node list` working, every
subsequent failure is invisible.

---

## Maintenance posture

A public ROS 2 library means tracking distros forever — Jazzy, Kilted, Lyrical,
and whatever lands next May — plus message-definition churn, issue triage, and
now a pinned Rust dependency that breaks on minor versions. `rclex` is roughly
1,300 commits of exactly that.

Three commitments make it survivable:

**Say what is implemented and decline to promise the rest.** The README states
supported distros, implemented primitives, and explicit non-goals in the first
screen — including, plainly, that type hashes are not published yet and why. A
small library with an honest scope is maintainable indefinitely. A half-finished
library with an implied promise of completeness is what makes maintainers burn
out and archive orgs, and there is a recent example in this exact niche.

**Keep the consumer.** E-Motion depends on `ros2_ex` in production, which means
breakage is found by someone who has to fix it. That is the forcing function
ROSiE did not have.

**Ship precompiled NIFs**, the way `zenohex` does, so a Nerves firmware build
does not need a Rust toolchain.

Package it separately from day one so the boundary is real, but keep it in the
existing umbrella repository until a second consumer appears. Two repos with one
consumer is friction with no benefit.

On the name: `ros2_ex` rather than an `rcl`-prefixed name, because the `rcl`
convention would be a lie — we are not wrapping it, and not wrapping it is the
point.

---

## Prior art

**`rclex`** — Elixir, NIF over `rcl`, actively maintained, CI against
Humble/Jazzy/Lyrical, ~1,300 commits, Nerves-oriented. Pub/sub is what the README
advertises. This is the incumbent, and the one-sentence answer to "why not just
use rclex" is: because it needs `rcl` on the target, and because we need actions.

**`ros2-client`** (Apache-2.0, 0.11.0, HEAD 2026-08-11) — the reference
implementation for everything above the DDS layer. Not a dependency, but read
continuously. `names.rs` and `service/wrappers.rs` are near-verbatim ports.

**RustDDS** (Apache-2.0, 0.14.1, tagged 2026-08-10, upstream at
`Atostek/RustDDS`) — the dependency. Very active; 2,044 commits.

**ROSiE** — a pure-Erlang ROS 2 implementation, Apache-2.0, more complete than
its obscurity suggests: `rosie_dds` (DDS/RTPS in Erlang), `rosie_rclerl`,
`rosie_interface_compiler` (a rebar3 plugin compiling `.msg`/`.srv`/`.action` to
Erlang modules), `colcon-rebar3`, and a GRiSP robot demo for Code BEAM Europe
2022. It began under `erlef` before moving to its own org. **The entire org was
archived on a single day, 2026-05-28.**

`rosie_interface_compiler` is directly relevant to M0 — porting a rebar3 IDL
parser to a Mix task is transcription, not design, and it is probably the highest
-leverage hour anyone can spend before starting.

The archive is the cautionary tale, and the lesson is not technical. A
coordinated shutdown of an entire org in one day is a funding or a person, not a
wall. What ROSiE lacked was a consumer who needed it to keep working.

**`zenohex`** — Rustler NIF over zenoh-rs with Nerves support and precompiled
NIFs. Not ROS, but its packaging and cross-compilation story is the model to copy.

---

## Open questions

- **Do we send the USER_DATA PR upstream, vendor a patch, or ship without type
  hashes?** This is the only unsolved item in the design and it should be decided
  before M1. Recommendation: ship v0.1 without, open the PR in parallel.
- Which distros does v0.1 claim? Recommend Jazzy and Kilted, with Humble a
  documented non-goal — and note that `Gid` is 24 bytes on Humble versus 16 on
  Iron and later, so Humble support is a wire-format conditional, not a flag.
- Does `mix ros2.gen` require an installed ROS 2, or do we vendor `.msg`
  definitions for common packages? Vendoring is friendlier and is a licensing and
  staleness question.
- Does anyone port `rosie_interface_compiler`, or do we write the IDL parser
  fresh? The port is probably faster and definitely better tested.
- How do we pin RustDDS across Nerves targets given a moving MSRV? Worth checking
  the Nerves toolchain's Rust version before committing to `=0.14.1`.

---

## References

- [RustDDS](https://github.com/jhelovuo/RustDDS) · [upstream `Atostek/RustDDS`](https://github.com/Atostek/RustDDS) · [docs.rs/rustdds](https://docs.rs/rustdds/latest/rustdds/)
- [`ros2-client`](https://github.com/jhelovuo/ros2-client) — reference implementation; see `names.rs` and `service/wrappers.rs`
- [`rclex`](https://github.com/rclex/rclex) · [on Hex](https://hex.pm/packages/rclex)
- [`zenohex`](https://github.com/biyooon-ex/zenohex) — NIF packaging and precompilation model
- [ROSiE org](https://github.com/orgs/rosie-project/repositories) (archived 2026-05-28) · [`rosie_interface_compiler`](https://github.com/rosie-project/rosie_interface_compiler) · [`rosie_dds`](https://github.com/rosie-project/rosie_dds)
- [`rmw/qos_profiles.h`](https://github.com/ros2/rmw/blob/rolling/rmw/include/rmw/qos_profiles.h) · [ROS 2 QoS design](https://design.ros2.org/articles/qos.html)
- [Topic and service name mapping](https://design.ros2.org/articles/topic_and_service_names.html) · [`rmw_fastrtps` namespace_prefix.cpp](https://github.com/ros2/rmw_fastrtps/blob/rolling/rmw_fastrtps_shared_cpp/src/namespace_prefix.cpp)
- [`rcl_action/names.c`](https://github.com/ros2/rcl/blob/rolling/rcl_action/src/rcl_action/names.c) — action wire decomposition
- [REP-2016](https://github.com/ros-infrastructure/rep/blob/master/rep-2016.rst) — type descriptions and RIHS hashing
- [foxglove/cdr](https://github.com/foxglove/cdr) — readable CDR reference implementation
