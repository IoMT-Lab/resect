# Workspace Layout {#workspace_layout}

This page maps the code: what lives in this repository, what lives in the
sibling repositories next to it, and how they're wired together.

## This repository

The repo root is a Dart **workspace** (`pubspec.yaml` names two member
packages) plus the engine assets and the launcher scripts:

    resect/
    ├── emulator_orchestrator/   All business logic + the CLI + the HTTP API.
    │   ├── bin/cli.dart         The command-line interface.
    │   ├── bin/server.dart      Headless HTTP API server.
    │   ├── lib/data/            Models, services, the artifact database,
    │   │                        the .emu repository.
    │   ├── lib/orchestrator/    EmulationOrchestrator, workflows (synthesis,
    │   │                        auto-tune), the engine abstraction, comms.
    │   ├── test/                Unit + integration tests.
    │   └── tool/                Headless dev/verification scripts.
    ├── emulator_ui/             The Flutter desktop app — views only.
    │   ├── lib/presentation/    Shell, the five screens, dialogs, widgets.
    │   ├── lib/providers/       Riverpod wiring between UI and orchestrator.
    │   └── test/                Widget + integration tests.
    ├── emulation_engine/        Engine assets: the portable Renode builds
    │                            (fetched via Git LFS; not a Dart package).
    ├── docs/                    These pages + the Doxyfile.
    ├── install.sh / run.sh      Setup and launch.
    └── resect.config            Shared key=value config (app + scripts).

(The CLI has its own page: @ref cli. Setup: @ref getting_started.)

The dependency direction is strict and one-way: `emulator_ui` depends on
`emulator_orchestrator`; the orchestrator knows nothing about Flutter.
That's what makes the CLI possible — see @ref architecture.

## The sibling repositories

Five supporting packages live in their own repos, checked out *next to*
this one (all under the same parent directory, e.g. `~/Development/`):

| Repo | Package | What it provides |
|---|---|---|
| `renode-dart` | `renode` | Drives the [Renode](@ref gloss_renode) process: launch, monitor commands, trace events. The only path to the emulator. |
| `callgraph-dart` | `callgraph` | Extracts [call graphs](@ref gloss_call_graph) from ELFs via objdump; ELF machine detection. |
| `hooks-dart` | `hooks` | [Hook](@ref gloss_hook) building blocks: template builders, the embedded Python modules, and the comms wire protocol (see @ref comms_virtualization). |
| `signatures-dart` | `signatures` | Runs Ghidra headlessly for [Ghidra extraction](@ref gloss_ghidra_extraction); the `FunctionSignature` types. |
| `lints-dart` | `iomt_lab_lints` | The shared analyzer ruleset (dev dependency). |

## How the wiring works (and why `pub get` behaves oddly)

`emulator_orchestrator/pubspec.yaml` declares these as **git dependencies
pinned to exact commits** — that's what a clean CI checkout builds against.
For day-to-day development, the git-ignored `pubspec_overrides.yaml` at the
workspace root redirects each package to its local sibling checkout
(`renode: {path: ../renode-dart}`, and so on), so your local edits to a
sibling take effect immediately without publishing anything.

Practical consequences:

- If a sibling checkout is missing, `dart pub get` falls back to the pinned
  git commit — fine for building, useless for editing that package.
- If you change a sibling's API, the pin in `pubspec.yaml` must eventually
  be updated to a pushed commit, or clean builds break while your local
  build works. (One such conflict is currently open — see
  [known debts](@ref known_debts).)
- `run.sh` also keeps hooks-dart's embedded Python module constants
  regenerated when the local override is active.

## The engine assets

`emulation_engine/` holds portable Renode builds. Resect pins a **patched**
build, and two of its properties directly affect anyone writing hook code:

- The [scope](@ref gloss_scope) argument to `AddHookAtSymbol` is a local
  patch — it doesn't exist in stock Renode, so hooks that use scopes only
  work on the pinned build (or newer patched ones).
- The Python interpreter embedded in Renode is IronPython **2.7**, so hook
  bodies must be written in Python 2 syntax.

See @ref hook_lifecycle for both in context. Which build directory is used
comes from `RENODE_PORTABLE`/`RENODE_BIN` in `resect.config`.

## In short

Two Dart packages in one workspace — orchestrator (logic, CLI) and UI
(views) — plus Renode assets, five pinned sibling repos redirected locally
by `pubspec_overrides.yaml`, and one shared `resect.config`.
