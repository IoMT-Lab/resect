# Comms Virtualization {#comms_virtualization}

Some firmware won't get anywhere with stub hooks alone: it *talks* to
devices — a sensor on I2C, a radio on SPI, a console on UART — and needs
answers, not just return codes.
[Comms virtualization](@ref gloss_comms_virtualization) forwards that bus
traffic out of the emulator to a virtual device on the host. This page
covers the pieces: classification, configuration, the forwarding hooks, the
wire protocol, and the signature gate that keeps the wrong functions from
being hooked.

## The idea

Instead of modeling an I2C peripheral inside
[Renode](@ref gloss_renode), Resect intercepts the firmware's bus *API
calls* (e.g. `HAL_I2C_Mem_Read`) with a forwarding [hook](@ref gloss_hook).
The hook extracts the call's arguments from CPU registers and the stack,
ships them over UDP to a [device handler](@ref gloss_device_handler)
running inside Resect, and writes the handler's answer back into the
firmware's buffer. The firmware believes it read a real device.

    firmware ──calls──▶ HAL_I2C_Mem_Read
                            │ forwarding hook (IronPython, in Renode)
                            ▼ UDP, one datagram per request
                    CommsBusService (Dart, in Resect)
                            ▼
                    DeviceHandler (e.g. ZeroDeviceHandler)

## Step 1 — Classify and assign

A name-pattern classifier (`NamePatternCommsClassifier`) tokenizes symbol
names and buckets them into a [comms class](@ref gloss_comms_class) and
read/write role — `HAL_I2C_Mem_Read` → i2c/read. You review and adjust the
result in the Comms tab; assignments are stored per symbol on the
[project](@ref gloss_project) (`commsAssignments`).

Both surfaces run this step through one shared merge
(`mergeCommsAssignments` in
`emulator_orchestrator/lib/services/comms/comms_assignment_merge.dart`):
entries already on the project win, symbols new to the call graph get the
classifier's suggestion, symbols dropped from the graph are pruned. The UI
re-runs it on every graph load; the CLI runs it at the start of every
`synthesize` and `autotune`, in memory — `autotune --save-comms` persists
the result back into the `.emu`. One caveat travels with the presence-wins
rule: an assignment records no provenance, so a persisted classifier
suggestion is indistinguishable from a deliberate reassignment and will
outrank an improved classifier later.

Name-pattern matching is deliberately simple, and it can be wrong in ways
that matter — which is why Step 3's gate exists: `get_i2c` *looks* like an
I2C read but is actually a zero-argument accessor that just returns a bus
handle.

## Step 2 — Configure and serve

Per protocol you choose a UDP port, a device handler, and whether the
protocol is virtualized at all. Bus servers are **session-scoped**: every
synthesis or auto-tune run brackets them through the shared
`startCommsSession`
(`emulator_orchestrator/lib/orchestrator/comms/comms_session.dart`), which
opens one `CommsBusService` UDP server per virtualized protocol at run
start and stops them when the run ends. Built-in handlers:
`ZeroDeviceHandler` (every read returns zeros — enough to get past polling
loops) and `RandomDeviceHandler`.

The defaults are the same on both surfaces: when nothing is explicitly
configured, a run virtualizes i2c/uart/spi with zero-fill servers on ports
1234/1235/1236 — exactly what `resect-cli` does. In the UI, the Comms tab
wins wholesale the moment ANY protocol's Virtualize toggle is on: the
session then uses the tab's ports and handler kinds verbatim.

## Step 3 — Build the forwarding hooks, with the arg-count gate

`buildCommsHooks`
(`emulator_orchestrator/lib/orchestrator/comms/comms_config.dart`) turns
each assignment into a catalog forwarder (`i2c_read`, `uart_read`, …).
The hook's argument extractor assumes the target follows a known ABI shape
— for the I2C read forwarder, the HAL convention where the transfer size is
the 6th argument (on ARM, that's a stack slot: registers r0–r3 carry the
first four arguments, the rest spill to the stack). Attach that extractor
to a function with fewer arguments and it reads stack *leftovers* —
garbage that becomes a bogus request.

So `buildCommsHooks` gates on the function's real parameter count, looked
up from the cached [Ghidra](@ref gloss_ghidra_extraction) signature: an
i2c read/write forwarder requires at least 6 parameters, a uart forwarder
at least 3. A function below the threshold (like the 0-argument `get_i2c`)
is left native — it runs its real body harmlessly. Unknown signatures
fail *open* (the hook is attached anyway), so this check only protects
firmware whose [Ghidra extraction](@ref gloss_ghidra_extraction) has been
run.

## The wire protocol

One fixed-size 41-byte datagram each way, defined identically in the hook
side (`comms.py`, in the `resect_hooks` package) and the Dart side —
Python struct format `'!cHHHH32s'`:

| Field | Size | Meaning (request → / response ←) |
|---|---|---|
| flags | 1 | → bit 6 = initial request; protocol one-hot: bit 3 = i2c, bit 4 = spi, bit 5 = uart; bit 2 = stop bit; bits 0–1 = handler id |
| u16 #1 | 2 | → unused / ← return value |
| u16 #2 | 2 | device/register address |
| u16 #3 | 2 | write-data length |
| u16 #4 | 2 | requested read size |
| payload | 32 | write data → / read data ← |

The payload is fixed at 32 bytes. A single transfer larger than that is
outside the protocol's current definition — the request's read-size field
is 16-bit and can *ask* for more than the response can carry. Known
protocol edge, tracked in `TODO.txt`; don't build on reads > 32 bytes.

## Per-bus status

Classification recognizes all three buses equally, but only I2C is wired all
the way through today.

| Bus | Classified | Forwarding hook | Wire path |
|---|---|---|---|
| I2C | yes | yes | works end to end |
| UART | yes | yes | broken (see below) |
| SPI | yes | no | not built |

@note **Deviation from the current code.**
**Today:** UART has a catalog forwarder and a Python remote module, but its
request packets don't parse: `comms.py` sends the protocol flag one-hot
(`uart = 0b100`), while the Dart side reads bits 3–5 as a sequential value
where `uart = 3`, so a UART request hits `Format.fromValue(4)` and throws
before any handler runs. SPI is dropped entirely — `buildCommsHooks` skips it
at `comms_config.dart:87` because there is no `spi_read`/`spi_write` catalog
descriptor, no `spi_hooks.dart`, no `spi_remote.py`, and no `extractSpiParams`.
**Planned:** reconcile the one-hot encoder with the sequential `Format` enum
so UART parses, and build the SPI forwarder + remote module + glue extractor
end to end. The wire pieces live in `resect_hooks` (@ref workspace_layout).
**Why:** the classifier already assigns UART and SPI roles, so firmware that
talks over those buses is silently unserved — the requests either throw
(UART) or are never forwarded at all (SPI).

## Precedence reminder

Comms hooks are pre-seeded after [overrides](@ref gloss_override) but
before [warm-start](@ref gloss_warm_start) hooks — an explicit override on
a symbol beats its comms assignment (see @ref hook_overlays).

## In short

Classify bus symbols (then fix the classifier's guesses), serve a UDP
device handler per protocol, and attach forwarding hooks — but only to
functions whose real signatures match the extractor's ABI assumptions.
Requests and responses are single 41-byte datagrams with a 32-byte payload.
