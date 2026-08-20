# Comms Virtualization {#comms_virtualization}

Some firmware won't get anywhere with stub hooks alone: it *talks* to
devices — a sensor on I2C, a radio on SPI, a console on UART — and needs
answers, not just return codes.
[Comms virtualization](@ref gloss_comms_virtualization) forwards that bus
traffic out of the emulator to a virtual device on the host. This page
covers the pieces: classification, configuration, the forwarding hooks and
the gates that decide which symbols get one, and the wire protocol.

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

The hook side finds those UDP servers via the `RENODE_COMMS_HOST`
environment variable (default `localhost`; the compose stack sets it to
`resect` on the Renode service so the in-container hook reaches back
across the network).

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
that matter: `get_i2c` *looks* like an I2C read but is actually a
zero-argument accessor that just returns a bus handle. Nothing downstream
catches that — Step 3's gates check identity, not signatures — so the
Comms tab review is where a misassignment gets fixed.

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
configured, a run virtualizes all three protocols with zero-fill servers on
ports i2c:1234, spi:1235, uart:1236 — exactly what `resect-cli` does. In the UI, the Comms tab
wins wholesale the moment ANY protocol's Virtualize toggle is on: the
session then uses the tab's ports and handler kinds verbatim.

## Step 3 — Build the forwarding hooks

`buildCommsHooks`
(`emulator_orchestrator/lib/orchestrator/comms/comms_config.dart`) turns
each assignment into a catalog forwarder (`i2c_read`, `uart_read`, …). Its
gates are identity checks on the assignment, in order:

- the symbol must be **classified** (unclassified entries are skipped);
- its protocol must be **virtualized** in the session's config;
- it must have a read/write **role** — a symbol with a known protocol but
  no role gets the catalog's default return-0 hook instead of a forwarder
  (on by default, so half-classified helpers like `HAL_I2C_StateGet` don't
  hang a virtualized protocol);
- a **catalog descriptor** must exist for `<protocol>_<role>` (this is
  what currently drops SPI — see the deviation note below).

Nothing checks the function's signature. The hook's argument extractor
assumes the target follows a known ABI shape — for the I2C read forwarder,
the HAL convention where the transfer size is the 6th argument (on ARM,
that's a stack slot: registers r0–r3 carry the first four arguments, the
rest spill to the stack). Attach that extractor to a function with fewer
arguments and it reads stack *leftovers* — garbage that becomes a bogus
request. That is the cost of a wrong assignment, and why the Comms tab
review in Step 1 matters.

## The wire protocol

One fixed-size 41-byte datagram each way, defined identically in the hook
side (`comms.py`, in the `resect_hooks` package) and the Dart side —
Python struct format `'!cHHHH32s'`:

| Field | Size | Meaning (request → / response ←) |
|---|---|---|
| flags | 1 | → bit 6 = initial request; protocol one-hot: bit 3 = i2c, bit 4 = spi, bit 5 = uart; bit 2 = stop bit; bits 0–1 = hardware identifier (HID), distinguishing multiple buses of one protocol |
| u16 #1 | 2 | → unused / ← return value |
| u16 #2 | 2 | device/register address |
| u16 #3 | 2 | write-data length |
| u16 #4 | 2 | requested read size |
| payload | 32 | write data → / read data ← |

The payload is fixed at 32 bytes. A single transfer larger than that is
outside the protocol's current definition — the request's read-size field
is 16-bit and can *ask* for more than the response can carry. Known
protocol edge; don't build on reads > 32 bytes.

## Per-bus status

Classification recognizes all three buses equally, but only I2C is wired all
the way through today.

| Bus | Classified | Forwarding hook | Wire path |
|---|---|---|---|
| I2C | yes | yes | works end to end |
| UART | yes | yes | broken (see below) |
| SPI | yes | shipped upstream, not cataloged | not wired |

@note **Deviation from the current code.**
**Today:** UART has a catalog forwarder and a Python remote module, but its
request packets don't parse: `comms.py` sends the protocol flag one-hot
(`uart = 0b100`), while the Dart side reads bits 3–5 as a sequential value
where `uart = 3`, so a UART request hits `Format.fromValue(4)` and throws
before any handler runs. SPI's engine pieces now exist — `resect_hooks`
1.5.1 ships `spiReadHook`/`spiWriteHook`, `spi_remote.py`, and the
`extractSpiParams_Simplex`/`_Duplex` glue extractors — but the Dart hook
catalog (`hook_catalog.dart`) still describes only `i2c_*`/`uart_*`, so
`buildCommsHooks` skips SPI at its descriptor gate
(`comms_config.dart:87`).
**Planned:** reconcile the one-hot encoder with the sequential `Format` enum
so UART parses, and add the `spi_read`/`spi_write` catalog descriptors to
wire the shipped SPI forwarders through.
**Why:** the classifier already assigns UART and SPI roles, so firmware that
talks over those buses is silently unserved — the requests either throw
(UART) or are never forwarded at all (SPI).

## Precedence reminder

Comms hooks are pre-seeded after [overrides](@ref gloss_override) but
before [warm-start](@ref gloss_warm_start) hooks — an explicit override on
a symbol beats its comms assignment (see @ref hook_overlays).

## In short

Classify bus symbols (then fix the classifier's guesses — no later gate
checks signatures for you), serve a UDP device handler per protocol, and
attach forwarding hooks to every classified, virtualized symbol whose role
has a catalog descriptor. Requests and responses are single 41-byte
datagrams with a 32-byte payload.
