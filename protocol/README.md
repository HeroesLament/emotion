# protocol

The wire contract between E-Motion Studio and an E-Motion controller.

This directory is at the umbrella root rather than inside `studio/` or a
controller app because neither owns it. Both are consumers, and putting the
contract inside one of them would quietly make that one authoritative.

## Files

| File                             | What it is                                  |
|----------------------------------|---------------------------------------------|
| `emotion-protocol.openrpc.json`  | The interface contract (OpenRPC 1.3.2) — **generated** |
| `DESIGN.md`                      | Drive layer, CiA 402, FOC, and the force path |
| `CARTESIAN.md`                   | Cartesian motion: the stream, limits, frames, moves |
| `PROGRAMS.md`                    | Programs, taught points, user frames, swappable tools, and where code lives |

## The stack

Nothing here is invented where a standard exists:

- **RFC 6455** WebSocket — transport, framing, and liveness. Liveness is the
  standard ping/pong frame pair; there is deliberately no application-level
  heartbeat method.
- **JSON-RPC 2.0** — envelope, request correlation, error codes, notifications.
- **OpenRPC 1.3.2** — the interface description in this directory.
- **CiA 402** — the drive profile below the controller. See `DESIGN.md`.

The only hand-rolled semantics are the subscription convention
(`streams/subscribe` and friends) and event replay (`events/since`), both of
which follow the shapes MCP and Ethereum's JSON-RPC established. Everything else
is somebody else's specification.

Bulk transfer — program source, logs, motion traces — is *not* on this link. It
is plain HTTP on the same host so it stays curl-able and does not compete with
live telemetry. The endpoints are listed under `x-bulkTransfer` in the document.

## Generated, not written

`emotion-protocol.openrpc.json` is produced by `mix exmo.openrpc` from the ExMo
Information Model in `apps/exhmi`. **Do not edit it.** Change the model and
regenerate.

    mix exmo.openrpc            # write the document
    mix exmo.openrpc --check    # fail if the committed file is stale

The reason is that the OPC UA projection derives from the same model. Two
hand-maintained descriptions of one controller agree right up until they don't,
and the divergence gets discovered by a client rather than by a test. `--check`
belongs in CI: a model change nobody regenerated for then fails the build
instead of shipping a document describing a controller that no longer exists.

Output is canonical — keys sorted, so an unchanged model regenerates
byte-identically and the diff on a commit is a change rather than a reshuffle.

The method surface is fixed and small. What those methods operate on is
discovered at runtime by browsing the model, exactly as an OPC UA client browses
an address space, which is why adding a seventh axis changes nothing about the
protocol. `x-nodes` carries a snapshot for tooling and review, and is marked
informative: a controller can be configured differently from the build that
generated the file, so a client browses rather than trusting it.

## Validating

Beyond `--check`, the document is verified against the official OpenRPC
meta-schema:

```sh
npm install @open-rpc/meta-schema
node -e "require('fs').writeFileSync('/tmp/meta.json', \
  JSON.stringify(require('@open-rpc/meta-schema').openrpcDocument))"
python3 -c "
import json
from jsonschema import Draft7Validator
schema = json.load(open('/tmp/meta.json'))
doc = json.load(open('emotion-protocol.openrpc.json'))
errs = list(Draft7Validator(schema).iter_errors(doc))
print('VALID' if not errs else f'{len(errs)} errors')
for e in errs[:10]:
    print(' ', '/'.join(str(p) for p in e.absolute_path), e.message[:200])
"
```

Note the version: the published meta-schema enumerates valid `openrpc` values
and tops out at **1.3.2**. Documents declaring 1.4.x are rejected by the
tooling regardless of what the specification website says.

## Three properties worth not breaking

**Streams are conflated; events are not.** A slow client receives the newest
stream frame and misses the ones in between, by design — stream `seq` skips and
that is normal. Event `seq` is gapless, and a gap means the client missed a
fault and must call `events/since`. An implementation that buffers stream frames
is non-conformant; it turns a momentarily slow client into one that falls
permanently behind.

**SI on the wire, always.** Metres, radians, seconds. There is no unit field
anywhere in this protocol and there must never be one — the unit is carried by
the schema type name. Encoder counts exist only below the drive layer.

**The Studio is never in the control loop.** It starts and observes motions; it
is not between the planner and the drives. A Studio that disconnects mid-motion
is a non-event for the robot.

## Not a safety function

Everything here — including force estimation and contact detection — is
functional capability, not a protective measure. Power and force limiting as a
*safety function* requires safety-rated sensing and safety-rated logic with a
demonstrated performance level, which a momentum observer running in the BEAM
is not and cannot become. See the safety section of `DESIGN.md`.

`motion/stop` asks a working controller, over a working network, to decelerate.
It cannot help when the controller has wedged, the link is down, or someone is
in the cell. The safety-rated stop is a physical circuit, and nothing in this
protocol is a substitute for it, an implementation of it, or a fallback for it.

`estop` appears in this protocol only as an observed boolean. There is no method
that asserts or clears it, and there must never be one.
