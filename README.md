# Resect

Resect builds high-fidelity emulators for embedded firmware. Given an ELF and
a Renode platform description (`.repl`), it iteratively discovers hardware-
dependent functions, substitutes them with Python hooks injected into Renode,
and produces a `.emu` project file that records the resolved hooks alongside
metadata, call graph, and synthesis results.

Two distinct hooking modes:

- **Per-function overrides.** Pick a specific Python body for one symbol —
  return constant, stateful read/write/increment with a Renode scope, or a
  custom artifact you authored. The synthesizer also discovers overrides
  automatically when the firmware faults on unhandled memory.
- **Comms-bus virtualization.** Classify functions on the call graph as
  i2c / spi / uart, then replace the entire bus interface at once with hooks
  that forward each transaction over UDP. The receiver can be the in-process
  zero/random handler, or any external listener you point at the port (e.g. a
  local Python script driving an FT232H to talk to a real I²C sensor).

Supported targets: ARM (via `arm-none-eabi-objdump`) and x86_64 (via stock
`objdump`). Call graph extraction lives in
[`callgraph-dart`](https://github.com/IoMT-Lab/callgraph-dart).

The application has three surfaces — a Flutter desktop GUI (the primary
interface), a CLI, and an HTTP API server — all backed by a shared
orchestrator. There is no Python backend; the orchestrator embeds the
[`renode-dart`](https://github.com/IoMT-Lab/renode-dart),
[`callgraph-dart`](https://github.com/IoMT-Lab/callgraph-dart), and
[`hooks-dart`](https://github.com/IoMT-Lab/hooks-dart) packages in-process and
launches a Renode portable binary directly.

## Architecture

```
┌───────────────────────┐  ┌───────────────────────┐  ┌───────────────────────┐
│   Flutter GUI         │  │   HTTP API server     │  │   CLI                 │
│   (emulator_ui)       │  │   (bin/server.dart)   │  │   (bin/cli.dart)      │
└───────────┬───────────┘  └───────────┬───────────┘  └───────────┬───────────┘
            │                          │                          │
            └──────────────────────────┴──────────────────────────┘
                                       │
                       ┌───────────────▼────────────────┐
                       │   emulator_orchestrator        │
                       │   • Workflows                  │
                       │     (emulator / analysis /     │
                       │      emulation / synthesizer)  │
                       │   • Engine abstraction         │
                       │     (CallGraphSource,          │
                       │      EmulationController,      │
                       │      EngineLifecycle,          │
                       │      TraceSource)              │
                       │   • Artifact DB (Drift)        │
                       │   • Comms bus (UDP forwarder)  │
                       └───────────────┬────────────────┘
                                       │
                       ┌───────────────▼────────────────┐
                       │   Dart engine (in-process)     │
                       │   • renode-dart  ──┐           │
                       │   • callgraph-dart │           │
                       │   • hooks-dart     │           │
                       └────────────────────┼───────────┘
                                            │ subprocess
                                ┌───────────▼───────────┐
                                │  Renode portable      │
                                │  (1.16.x; patched     │
                                │   build for scope     │
                                │   arg on              │
                                │   AddHookAtSymbol)    │
                                └───────────────────────┘
```

### Workspace layout

This is a [Dart workspace](https://dart.dev/tools/pub/workspaces) with two
packages sharing one dependency resolution:

```
resect/                              ← workspace root
├── pubspec.yaml                     ← workspace manifest (2 packages)
├── pubspec_overrides.yaml           ← (optional, gitignored) routes
│                                       hooks/renode/callgraph/lints to
│                                       local sibling checkouts for dev
├── install.sh                       ← one-time setup
├── run.sh                           ← launches the Flutter app
├── resect.config                    ← paths/ports/prefs (gitignored;
│                                       managed by Tools → System
│                                       Configuration UI or by install.sh)
├── emulation_engine/                ← Renode portables + LFS-tracked
│                                       legacy binary; no Python backend
│
├── emulator_orchestrator/           ← pure Dart package (no Flutter)
│   ├── bin/
│   │   ├── cli.dart                 ← CLI entry
│   │   └── server.dart              ← HTTP API server entry
│   └── lib/
│       ├── api/                     ← shelf_router HTTP routes
│       ├── data/
│       │   ├── database/            ← Drift/SQLite artifact store
│       │   ├── models/              ← Emulator, CallGraph, etc.
│       │   ├── repositories/        ← .emu file persistence
│       │   └── services/            ← HookCatalog, classifier,
│       │                              fidelity, scope suggester
│       └── orchestrator/
│           ├── emulation_orchestrator.dart
│           ├── comms/               ← UDP forwarder + device handlers
│           ├── engine/              ← engine abstraction + Dart impl
│           │   └── dart/            ← wraps renode-dart in-process
│           └── workflows/           ← emulator / analysis /
│                                      emulation / synthesizer
│
└── emulator_ui/                     ← Flutter Linux desktop app
    └── lib/
        ├── main.dart
        ├── core/                    ← theme, paths
        ├── providers/               ← Riverpod state
        └── presentation/
            ├── dialogs/
            ├── screens/
            │   ├── library/         ← projects + documents
            │   ├── callgraph/       ← graph viewer + metadata sidebar
            │   ├── comms/           ← bus classifier + virtualization
            │   ├── synthesize/      ← synth controls + report
            │   └── publish/         ← .resc export
            └── widgets/
```

### Sibling Dart packages

Four siblings of resect are consumed as git-pinned dependencies in
`emulator_orchestrator/pubspec.yaml`:

| Package | Role |
|---|---|
| [`renode-dart`](https://github.com/IoMT-Lab/renode-dart) | Wraps the Renode portable binary as a Dart subprocess; speaks Renode's control protocol. |
| [`callgraph-dart`](https://github.com/IoMT-Lab/callgraph-dart) | Builds call graphs from ELF files via `arm-none-eabi-objdump` / `objdump`. |
| [`hooks-dart`](https://github.com/IoMT-Lab/hooks-dart) | Typed hook builders (`returnHook`, `readHook`, `writeHook`, `incrementHook`, `i2cReadHook`, `i2cWriteHook`, `uartReadHook`, `uartWriteHook`) and the UDP wire format. |
| [`lints-dart`](https://github.com/IoMT-Lab/lints-dart) | Shared analysis_options. |

For local development against any of them, drop a `pubspec_overrides.yaml`
at the workspace root pointing to sibling checkouts:

```yaml
dependency_overrides:
  hooks:
    path: ../hooks-dart
  renode:
    path: ../renode-dart
  callgraph:
    path: ../callgraph-dart
  iomt_lab_lints:
    path: ../lints-dart
```

`run.sh` detects this and runs hooks-dart's `tool/gen_system_modules.dart
--check` on every launch so the embedded Python-module mirror never drifts
from the canonical `.py` sources.

## Concepts

**Emulator (`.emu` file).** JSON project file persisted under
`~/.config/call_graph_viewer/projects/`. Carries the ELF + `.repl` paths,
emulation config (start/end symbols, pauseOnUnhandled), per-symbol hook
overrides + scopes, comms classification + per-protocol config, the cached
call graph, the last synthesis result, and a small list of attached
documents.

**Hook catalog.** A registry of typed builders defined in
`emulator_orchestrator/lib/data/services/hook_catalog.dart`, wired through
to hooks-dart's [`simple_hooks.dart`](https://github.com/IoMT-Lab/hooks-dart/blob/main/lib/src/simple_hooks.dart).
Seven default artifacts are seeded per symbol at firmware registration:
two legacy return-N bodies, two catalog `returnHook(N)` bodies, and `read`
/ `write` / `increment` variants (with both `value=0` and `value=1`
presets, for a total of ten on a freshly-registered firmware).

**Forced overrides + scope.** From the call-graph tab's metadata sidebar,
any non-comms symbol can be pinned to a specific hook artifact, with an
optional Renode `scope` string. Scope is auto-suggested from the symbol
name (`LL_RCC_HSE_Enable` → `HSE`) and editable. Scoped hooks share a
per-scope Python `globals()` inside Renode, so e.g. a stateful `write`
to one symbol becomes visible to a stateful `read` on another in the
same scope. **The scope arg is only honored by the patched Renode
portable** (`renode_1.16.1+20260512gitf8adfbff0-portable` or newer);
stock 1.16.0 silently drops it.

**Comms-bus virtualization.** A separate tab classifies call-graph
functions as `i2c` / `spi` / `uart` / `unclassified` using token-aware
name matching. For each protocol you can configure a UDP port + device
handler (built-in: zero-fill, random; or external by leaving the
in-process server off and binding your own listener). Toggling
Virtualize on stages bus hooks (read / write / return0 fill-in for
role-less symbols) that forward each transaction over UDP. The
external-listener pattern is what enables driving a real sensor over an
FT232H — see `emulation_engine/run_client.py` for a starting point.

**Synthesizer.** Drives Renode with `pauseOnUnhandled=true`; on every
unhandled-access pause, the synthesizer pre-seeds the user's overrides
and comms-bus hooks, then iteratively applies hook candidates from the
artifact DB until firmware runs cleanly or a symbol exhausts all
candidates. The Synthesize report tags each resolved hook with its
source (OVERRIDE / COMMS / CACHED / SYNTH).

**Fidelity metrics.** Coverage + subgraph + intact/degraded/hooked
counts, computed from the call graph and the executed-symbol trace.
Surfaced in the Synthesize report.

**Artifact database.** SQLite store via Drift at
`~/.config/call_graph_viewer/artifact_library/artifacts.db`. Keyed on
(elfHash, symbolName); populated when an ELF first opens. The dropdown
in the metadata sidebar dedupes by code body so the user sees one entry
per distinct hook variant.

## Tabs (UI tour)

| Tab | Surface |
|---|---|
| **LIBRARY** | Recent projects, new project dialog, open/save/close. Below the open project: attach documents (PDFs, datasheets, source listings) that travel with the `.emu`. |
| **CALL GRAPH** | Force-directed graph viewer, symbols list with search, metadata sidebar with function instructions, FORCE OVERRIDE dropdown + SCOPE field, PREFERRED HOOK dropdown, calls/called-by navigation. |
| **COMMS** | Class selector (i2c/spi/uart/unclassified) with per-class counts. Two-pane main: collapsible call-graph tree on the left (per-class), Python interface config + staged-hooks readout on the right. Virtualize toggle, fill-in-return0 checkbox. |
| **SYNTHESIZE** | Run config (start-from, end-at, memory map), console with live event stream, Run / Synthesize controls, report card with fidelity bar + per-row source tags. |
| **PUBLISH** | Export the current resolved-hooks set to a standalone Renode `.resc` script. |

Tools → System Configuration edits `resect.config` for paths (Flutter
SDK, objdump variants, engine dir, Renode binary), the HTTP API port,
and the autosave preference.

## Requirements

| Dependency | Purpose |
|---|---|
| Flutter SDK (Dart >= 3.9) | GUI + Dart toolchain |
| clang, cmake, ninja-build | Flutter Linux desktop build |
| libgtk-3-dev, liblzma-dev, pkg-config | GTK runtime + build glue |
| gcc-arm-none-eabi | `arm-none-eabi-objdump` for ARM call graphs |
| git-lfs | Fetches the stock Renode portable |
| Renode portable (patched) | Required for scope-arg support — patched build available from the project maintainers |

Optional: VirtualBox + Vagrant for the CI/CD test harness; opt-in via
`./install.sh --with-vagrant-test`.

## Install

### Automated

```bash
git clone git@github.com:IoMT-Lab/resect.git
cd resect
./install.sh                  # or: ./install.sh --with-vagrant-test
```

`install.sh` provisions system packages, ensures Flutter is on PATH (or
clones a stable SDK to `~/Development/flutter`), runs `git lfs pull` for
the Renode portable, and writes `resect.config` with detected paths.

### Manual

```bash
# 1. System packages
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  gcc-arm-none-eabi git git-lfs curl

# 2. Flutter SDK (git install — required for Linux desktop)
git clone https://github.com/flutter/flutter.git -b stable ~/Development/flutter
echo 'export PATH="$HOME/Development/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter precache
flutter config --enable-linux-desktop

# 3. Renode binary (LFS)
cd resect/emulation_engine
git lfs install && git lfs pull

# 4. Patched Renode portable
#    Drop the renode_1.16.1+...-portable directory into emulation_engine/
#    and point RENODE_BIN / RENODE_PORTABLE at it via resect.config or
#    Tools → System Configuration.

# 5. Dart workspace
cd ..
dart pub get
```

Verify:

```bash
flutter doctor -v
dart analyze emulator_orchestrator
```

## Run

```bash
./run.sh
```

`run.sh` runs Drift codegen (`build_runner build`) if the generated files
are missing, runs hooks-dart's embedded-modules drift safeguard when a
local override is active, then launches `flutter run -d linux`. No
Python server is involved. Exit Flutter normally with `q`.

## CLI

Headless commands for scripting. Run from the workspace root:

```bash
dart run emulator_orchestrator:cli --help
```

Available commands:

| Command | Purpose |
|---|---|
| `create` | Create a new `.emu` project file |
| `callgraph` | Generate a call graph from an ELF |
| `synthesize` | Run the automated hook synthesizer |
| `fidelity` | Compute fidelity metrics for a hook set |
| `export` | Export an emulator to a standalone `.resc` script |

Each command has `--help` for its options. Global flags:

| Flag | Purpose |
|---|---|
| `--engine-dir <path>` | Path to `emulation_engine/` (auto-detected if omitted) |
| `--backend-url <url>` | Connect to an existing engine instance (skips auto-start) |

## HTTP API

```bash
dart run emulator_orchestrator:server --port 8080
```

| Method | Path | Description |
|---|---|---|
| GET | `/status` | Orchestrator state + loaded emulator info |
| POST | `/emulator` | Create a new emulator |
| GET | `/emulator` | Get the current loaded emulator |
| POST | `/callgraph` | Generate a call graph from an ELF |
| POST | `/synthesizer/run` | Run synthesis |
| GET | `/synthesizer/events` | SSE stream of synthesis progress |
| POST | `/emulation/start` | Start emulation |
| POST | `/emulation/stop` | Reset emulation |
| POST | `/fidelity` | Compute fidelity metrics |

All endpoints accept/return JSON. See
`emulator_orchestrator/lib/api/api_server.dart` for request/response
schemas.

## Development

### Sibling-checkout workflow

Clone the four sibling packages next to resect (under the same parent
directory by default):

```
~/Development/
├── resect/
├── renode-dart/
├── callgraph-dart/
├── hooks-dart/
└── lints-dart/
```

Then drop `pubspec_overrides.yaml` at the resect workspace root as shown
above. The override file is gitignored.

If you change `hooks-dart/lib/resources/python/*.py`, regenerate the
embedded mirror with:

```bash
cd ~/Development/hooks-dart
dart run tool/gen_system_modules.dart
```

`./run.sh` runs `--check` on every launch and surfaces drift before the
app starts.

### Tests

```bash
dart test emulator_orchestrator
cd emulator_ui && flutter test
```

### Drift codegen

After changes to `artifact_database.dart`:

```bash
cd emulator_orchestrator
dart run build_runner build --delete-conflicting-outputs
```

### Static analysis

```bash
dart analyze emulator_orchestrator
flutter analyze emulator_ui
```

### Release builds

```bash
# Flutter GUI
cd emulator_ui
flutter build linux --release         # → build/linux/x64/release/bundle/

# CLI as self-contained executable
cd ..
dart compile exe emulator_orchestrator/bin/cli.dart -o resect-cli
```

## Data storage

| Path | Contents |
|---|---|
| `~/.config/call_graph_viewer/projects/` | Saved `.emu` project files |
| `~/.config/call_graph_viewer/artifact_library/artifacts.db` | SQLite artifact DB |
| `<repo>/resect.config` | Local paths, ports, autosave preference (gitignored) |
| `/tmp/renode_logs/renode.log` | Renode stdout/stderr capture |

## Technology stack

| Layer | Technology |
|---|---|
| GUI | Flutter 3.x (Linux desktop) |
| State management | Riverpod 2.x |
| Engine | renode-dart + callgraph-dart + hooks-dart (all in-process) wrapping a Renode portable subprocess |
| Hook templates | hooks-dart `simple_hooks.dart` builders + Python module substitution |
| Comms forwarder | hooks-dart UDP wire format (binary protocol; one-hot selector for i2c/spi/uart) |
| Artifact storage | Drift 2.x + SQLite3 |
| HTTP API | shelf + shelf_router |
| Graph viewer | graphview 1.2 |
| Call graph extraction | `arm-none-eabi-objdump` (ARM) / `objdump` (x86_64) |

## License

TBD
