# Workspace Layout {#workspace_layout}

This page maps the code: what lives in this repository, where the engine
packages come from, and how the container image is built from both.

## This repository

The repo root is a Dart **workspace** (`pubspec.yaml` names two member
packages) plus the container definitions and the launcher scripts:

    resect/
    ├── emulator_orchestrator/   All business logic + the CLI + the HTTP API.
    │   ├── bin/cli.dart         The command-line interface.
    │   ├── bin/server.dart      Headless HTTP API server.
    │   ├── lib/api/             The headless HTTP API server.
    │   ├── lib/config/          resect.config loading, its schema, module
    │   │                        components.
    │   ├── lib/core/            App paths and shared constants.
    │   ├── lib/data/            database/, models/, repositories/ — the
    │   │                        artifact database and the .emu repository.
    │   ├── lib/orchestrator/    EmulationOrchestrator, workflows (analysis,
    │   │                        emulation, emulator, synthesizer), the
    │   │                        auto-tune engine + report writer (directly
    │   │                        here, not a workflow), the engine
    │   │                        abstraction, comms.
    │   ├── lib/services/        Domain services: analysis, comms, external,
    │   │                        hooks, llm, quality, rag.
    │   ├── test/                Unit + integration tests.
    │   └── tool/                Headless dev/verification scripts.
    ├── emulator_ui/             The Flutter desktop app — views only.
    │   ├── lib/presentation/    Shell, the five screens, dialogs, widgets.
    │   ├── lib/providers/       Riverpod wiring between UI and orchestrator.
    │   └── test/                Widget + integration tests.
    ├── docker/                  Dockerfile, entrypoint, env files, in-image
    │                            resect.config.
    ├── compose.yml              The container stack (see @ref containers).
    ├── .env                     Compose defaults (display sockets, env-file pick).
    ├── scripts/                 install / build / run_cli / run_gui / run_vnc /
    │                            stop / clean / uninstall.
    ├── workdir/                 Bind-mounted into the container as /workdir
    │                            (gitignored apart from the shipped example).
    ├── emulation_engine/        Optional host-side portable Renode builds
    │                            (not a Dart package, not required by the
    │                            container path).
    ├── docs/                    These pages + the Doxyfile.
    ├── install.sh / run.sh      Host setup and launch.
    └── resect.config            Shared key=value config (app + scripts).

(The CLI has its own page: @ref cli. Setup: @ref getting_started.
Containers: @ref containers.)

The dependency direction is strict and one-way: `emulator_ui` depends on
`emulator_orchestrator`; the orchestrator knows nothing about Flutter.
That's what makes the CLI possible — see @ref architecture.

## The engine packages

Four supporting packages are **hosted** on the project's package repository
(`https://nexus.medmakers.io/repository/pub`) and declared as normal
versioned dependencies in `emulator_orchestrator/pubspec.yaml`:

| Package | Version | What it provides |
|---|---|---|
| `renode` | 2.2.2 | Drives [Renode](@ref gloss_renode): the client, monitor commands, state/function-call/unhandled-access events. The only path to the emulator. |
| `resect_callgraph` | ^1.0.0 | Extracts [call graphs](@ref gloss_call_graph) from ELFs via objdump; ELF machine detection. |
| `resect_hooks` | ^1.5.1 | [Hook](@ref gloss_hook) building blocks: template builders, the embedded Python modules, and the comms wire protocol (see @ref comms_virtualization). |
| `resect_signatures` | ^1.0.0 | Runs Ghidra headlessly for [Ghidra extraction](@ref gloss_ghidra_extraction); the `FunctionSignature` / `DataSymbol` types. |

A shared analyzer ruleset (`iomt_lab_lints`) comes in as a dev dependency.

So a clean `dart pub get` resolves everything from the hosted repository —
no sibling checkouts required, which is what makes the container build a
plain `pubspec.lock` restore.

**Publishing a change to one of these packages requires a version bump.**
The hosted repository serves immutable versions; pushing the same version
number again does not propagate, and `pubspec.lock` will keep resolving the
old code. Bump the version, publish, then update the constraint here.

For day-to-day co-development of an engine package, add a git-ignored
`pubspec_overrides.yaml` at the workspace root redirecting that package to a
local checkout:

    dependency_overrides:
      resect_hooks:
        path: ../hooks-dart

(One caveat: `run.sh`'s override-drift check greps the overrides file for
`hooks:`, which this `resect_hooks:` spelling does not match — the embedded
Python module regeneration it triggers won't run for it.)

Two consequences worth internalizing: an override only affects *your host*
build — the container image builds from `pubspec.lock` and always gets the
hosted version — and any local edit must be published (with a bump) before
CI or anyone else sees it.

## The engine assets

`emulation_engine/` holds portable Renode builds for the **host** path. The
container path doesn't use it at all: the `renode` service is its own image.
Either way, Resect pins a **patched** build, and two of its properties
directly affect anyone writing hook code:

- The [scope](@ref gloss_scope) argument to `AddHookAtSymbol` is a local
  patch — it doesn't exist in stock Renode, so hooks that use scopes only
  work on the patched build.
- The Python interpreter embedded in Renode is IronPython **2.7**, so hook
  bodies must be written in Python 2 syntax.

See @ref hook_lifecycle for both in context. Which build a host run uses
comes from `RENODE_PORTABLE`/`RENODE_BIN` in `resect.config`; which server it
*connects to* comes from `RENODE_HOST`/`RENODE_PORT`
(@ref orchestrator_engine).

## How the container image is built

`docker/Dockerfile` is one two-stage build on the shared builder image
(`nexus.medmakers.io/docker/flutter`): copy the two packages plus
`pubspec.yaml`/`pubspec.lock`, `flutter pub get`, run Drift codegen, then
build **both surfaces** — `dart build cli` and `flutter build linux` — into a
single `ubuntu:24.04` runtime with objdump, SQLite, GTK, the Wayland/X11
client libraries, and the Xvfb/x11vnc pieces. The entrypoint's mode argument
(cli / gui / vnc) picks which surface runs. Details in @ref containers.

## In short

Two Dart packages in one workspace — orchestrator (logic, CLI) and UI
(views) — plus four hosted engine packages (`renode`, `resect_callgraph`,
`resect_hooks`, `resect_signatures`), a Docker stack built from the same
`pubspec.lock`, and one shared `resect.config`. Local package edits go
through a git-ignored override; shipped ones go through a version bump.
