# Resect

Firmware emulator creation and analysis tool. Resect automates the process
of building high-fidelity emulators for provided firmware by iteratively discovering
and substituting hardware-dependent functions with software hooks.

Supports: ARM, X86

The project has three interfaces — a Flutter desktop GUI, a CLI, and an HTTP API
server — all backed by a shared orchestration layer that communicates with a
Python emulation engine (Renode).

## Architecture

```
                         ┌──────────────────────────────────┐
                         │        emulation_engine          │
                         │  (Python — Renode, call graph    │
                         │   analysis, Socket.IO server)    │
                         └──────────┬───────────────────────┘
                                    │ Socket.IO (:12356)
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
┌───────▼────────┐  ┌──────────────▼───────────────┐  ┌────────▼───────┐
│  Flutter GUI   │  │   emulator_orchestrator       │  │  HTTP API      │
│  (emulator_ui) │  │                               │  │  Server        │
│                │  │  ┌─────────────────────────┐  │  │  (bin/server)  │
│  Riverpod      │  │  │  Workflows              │  │  │                │
│  providers ────┼──┤  │  • EmulationWorkflow    │  │  │  shelf_router  │
│                │  │  │  • SynthesizerWorkflow  │  │  │  REST routes   │
│  Presentation  │  │  │  • AnalysisWorkflow     │  │  │  SSE events    │
│  widgets       │  │  │  • EmulatorWorkflow     │  │  └────────────────┘
└────────────────┘  │  └─────────────────────────┘  │
                    │                               │  ┌────────────────┐
                    │  ┌─────────────────────────┐  │  │  CLI           │
                    │  │  Services (Socket.IO)    │  │  │  (bin/cli)     │
                    │  │  • LifecycleService      │  ├──┤                │
                    │  │  • CallgraphService      │  │  │  create        │
                    │  │  • TraceService          │  │  │  callgraph     │
                    │  │  • FilteredTraceService  │  │  │  synthesize    │
                    │  └─────────────────────────┘  │  │  fidelity      │
                    │                               │  │  export         │
                    │  ┌─────────────────────────┐  │  └────────────────┘
                    │  │  Data Layer              │  │
                    │  │  • Models (Emulator,     │  │
                    │  │    CallGraph, Symbol…)   │  │
                    │  │  • Artifact DB (Drift)   │  │
                    │  │  • EmulatorRepository    │  │
                    │  └─────────────────────────┘  │
                    └───────────────────────────────┘
```

### Workspace layout

This is a [Dart workspace](https://dart.dev/tools/pub/workspaces) with two
packages sharing a single dependency resolution:

```
Resect/                              ← workspace root (this repo)
├── pubspec.yaml                     ← workspace manifest
├── install.sh                       ← one-time setup for fresh Ubuntu
├── run.sh                           ← starts Python server + Flutter UI
├── emulation_engine/                ← Python backend (cloned separately)
│
├── emulator_orchestrator/           ← pure Dart package (no Flutter)
│   ├── pubspec.yaml
│   ├── bin/
│   │   ├── cli.dart                 ← CLI entry point
│   │   └── server.dart              ← headless HTTP API server
│   ├── lib/
│   │   ├── emulator_orchestrator.dart  ← barrel exports
│   │   ├── api/                     ← shelf HTTP routes
│   │   ├── core/                    ← constants, paths
│   │   ├── data/
│   │   │   ├── database/            ← Drift/SQLite artifact store
│   │   │   ├── models/              ← Emulator, CallGraph, Symbol…
│   │   │   ├── repositories/        ← .emu file persistence
│   │   │   └── services/            ← Socket.IO service clients
│   │   └── orchestrator/
│   │       ├── emulation_orchestrator.dart
│   │       ├── python_server.dart   ← manages Python subprocess
│   │       ├── events/              ← event types for UI/API
│   │       ├── exceptions/
│   │       └── workflows/           ← business logic sequences
│   └── test/
│
└── emulator_ui/                     ← Flutter desktop app
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart
    │   ├── core/theme.dart
    │   ├── providers/app_providers.dart  ← Riverpod state
    │   └── presentation/
    │       ├── screens/
    │       ├── dialogs/
    │       └── widgets/
    └── linux/                       ← CMake build for Linux desktop
```

### Key concepts

**Emulator (.emu file)** — A JSON project file containing the ELF path, platform
description (.repl), emulation configuration (start/end symbols), and resolved
hooks. Created manually or by the synthesizer.

**Synthesizer** — Iterative loop that runs firmware under Renode with
`pauseOnUnhandled=true`. Each time an unhandled memory access pauses execution,
the synthesizer identifies the enclosing function, looks up candidate hooks in
the artifact database, applies one, resets, and retries. Continues until firmware
runs cleanly or a symbol exhausts all hook candidates.

**Artifact database** — SQLite store (via Drift ORM) holding hook implementations
keyed by ELF hash and symbol name. Populated during call graph generation.

**Fidelity metrics** — Measures how much of the firmware's call graph is covered
by the current set of hooks, computed from the call graph structure and traversal
data.

## Installation (fresh Ubuntu)

### Prerequisites

| Dependency | Purpose |
|---|---|
| Flutter SDK (>= 3.22) | GUI and Dart toolchain |
| Python 3, pipenv | emulation_engine backend |
| Renode (bundled via Git LFS) | ARM emulation |
| clang, cmake, ninja-build | Flutter Linux desktop build |
| libgtk-3-dev, liblzma-dev | GTK runtime for Flutter |
| gcc-arm-none-eabi | ARM objdump for call graph analysis |
| pkg-config | Build dependency resolution |
| git-lfs | Fetching the Renode binary |

### Automated setup

```bash
git clone <Resect-repo-url> Resect
cd Resect

# Install everything
./install.sh
```

The install script handles system packages, Flutter SDK, Python virtualenv,
Git LFS pull for the Renode binary, and `dart pub get` for both workspace
packages.

### Manual setup

If you prefer to install manually or the script fails partway through:

```bash
# 1. System packages
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  gcc-arm-none-eabi python3-pip pipenv git git-lfs curl

# 2. Flutter SDK (git install — required for Linux desktop)
git clone https://github.com/flutter/flutter.git -b stable ~/development/flutter
echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter precache
flutter config --enable-linux-desktop

# 3. Python backend
cd Resect/emulation_engine
git lfs install && git lfs pull
pipenv install --dev

# 4. Dart workspace
cd ..
dart pub get
```

Verify with:

```bash
flutter doctor -v          # Linux toolchain should show all green
dart pub get               # should resolve without errors
dart analyze emulator_orchestrator   # 0 errors, 0 warnings
```

## Usage

### Flutter GUI

The primary interface. Starts the Python backend automatically, then launches
a desktop window with call graph visualization, emulator management, and
synthesis controls.

```bash
cd Resect
./run.sh
```

`run.sh` handles: Renode validation, port cleanup, Python server startup,
server readiness checks, then `flutter run -d linux`. On exit it kills the
Python server.

### CLI

Headless commands for scripting and CI. Each command that needs the Python
backend can either auto-start it (`--engine-dir`) or connect to an existing
instance (`--backend-url`).

Run from the workspace root:

```bash
# Show help
dart run emulator_orchestrator:cli --help
```

#### Commands

**create** — Create a new emulator project file.

```bash
dart run emulator_orchestrator:cli create \
  --name my-emulator \
  --elf /path/to/firmware.elf \
  --repl /path/to/platform.repl \
  -o my-emulator.emu
```

**callgraph** — Generate a call graph from an ELF file.

```bash
dart run emulator_orchestrator:cli callgraph \
  --elf /path/to/firmware.elf \
  --format summary \
  -o callgraph.json
```

**synthesize** — Run the automated hook synthesizer.

```bash
dart run emulator_orchestrator:cli synthesize \
  --elf /path/to/firmware.elf \
  --repl /path/to/platform.repl \
  --start-from main \
  --end-at exit_func \
  --save-emulator result.emu
```

**fidelity** — Compute fidelity metrics.

```bash
dart run emulator_orchestrator:cli fidelity \
  --elf /path/to/firmware.elf \
  --hooks func_a,func_b \
  --format summary
```

**export** — Export an emulator to a standalone Renode `.resc` script.

```bash
dart run emulator_orchestrator:cli export \
  --emulator result.emu \
  -o result.resc
```

### HTTP API server

RESTful API for programmatic access without the GUI. Useful for integration
with external tools, CI pipelines, or web frontends.

```bash
dart run emulator_orchestrator:server --port 8080
```

#### Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/status` | Orchestrator state, loaded emulator info |
| POST | `/emulator` | Create a new emulator |
| GET | `/emulator` | Get current loaded emulator |
| POST | `/callgraph` | Generate call graph for an ELF file |
| POST | `/synthesizer/run` | Run automated hook synthesis |
| GET | `/synthesizer/events` | SSE stream of synthesis progress |
| POST | `/emulation/start` | Start emulation |
| POST | `/emulation/stop` | Stop/reset emulation |
| POST | `/fidelity` | Compute fidelity metrics |

All endpoints accept/return JSON. See the source at
`emulator_orchestrator/lib/api/api_server.dart` for request/response schemas.

## Development

### Running in development

```bash
# Terminal 1 — start Python backend manually (alternative to run.sh)
cd Resect/emulation_engine
RENODE_EXECUTABLE=$(pwd)/renode_1.16.0-dotnet_portable/renode \
  pipenv run python -m emulation_engine.engine

# Terminal 2 — run Flutter with hot reload
cd Resect/emulator_ui
flutter run -d linux
```

Press `r` in the Flutter terminal for hot reload, `R` for hot restart.

### Running tests

```bash
# Orchestrator unit tests (from workspace root)
dart test emulator_orchestrator

# Flutter widget tests (if any)
cd emulator_ui && flutter test
```

### Code generation (Drift database)

After changing `artifact_database.dart` schema:

```bash
cd emulator_orchestrator
dart run build_runner build --delete-conflicting-outputs
```

### Static analysis

```bash
dart analyze emulator_orchestrator
flutter analyze emulator_ui
```

### Building a release binary

```bash
# Flutter GUI
cd emulator_ui
flutter build linux --release
# Output: build/linux/x64/release/bundle/

# CLI as self-contained executable
cd ..
dart compile exe emulator_orchestrator/bin/cli.dart -o resect-cli
```

### Data storage

All persistent data lives under `~/.config/call_graph_viewer/`:

| Path | Contents |
|---|---|
| `projects/` | Saved `.emu` emulator files |
| `artifact_library/artifacts.db` | SQLite artifact database |

## Technology stack

| Layer | Technology |
|---|---|
| GUI framework | Flutter 3.x (Linux desktop) |
| State management | Riverpod 2.x |
| Backend communication | Socket.IO 2.x (4 namespaces) |
| Database ORM | Drift 2.x + SQLite3 |
| HTTP API | shelf + shelf_router |
| Graph visualization | graphview 1.2 |
| Emulation engine | Renode 1.16 (Python, separate repo) |
| Call graph analysis | arm-none-eabi-objdump |

## License

TBD
