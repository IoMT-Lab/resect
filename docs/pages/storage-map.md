# Storage Map: What Resect Writes Where {#storage_map}

Everything Resect persists, in one place. When you're debugging "where did
that come from?", start here.

## The config root: `~/.config/call_graph_viewer/`

All durable app data lives under one directory (paths centralized in
`emulator_orchestrator/lib/core/app_paths.dart` — the directory name is
historical):

    ~/.config/call_graph_viewer/
    ├── artifact_library/
    │   └── artifacts.db            Model #1: the artifact database.
    ├── projects/                   Default home for .emu files (model #2) …
    │   └── <project-id>/documents/ … and per-project attached documents.
    └── recent_emulators.json       The Library tab's recent-projects list.

(The two models have their own pages: @ref model_artifacts and
@ref model_projects.)

## Per-project files

A saved [project](@ref gloss_project) grows sibling files next to its
project directory:

| Path | What | Written by |
|---|---|---|
| `<name>.emu` | The project itself — one JSON file. | Save/autosave via `EmulatorRepository`. |
| `manifests/<run_id>.json` | One [manifest](@ref gloss_manifest) per synthesis run. | Both the UI and headless [auto-tune](@ref gloss_autotune). |
| `autotune_reports/<timestamp>/` | Per-[round](@ref gloss_round) reports from a headless auto-tune session: `round_NN.md`, `round_NN_manifest.json`, `round_NN_trace.txt`, `summary.md`. | The CLI's report [sink](@ref gloss_sink). |
| `rag_index.db` | The per-project [RAG](@ref gloss_rag) index (chunked documents + embeddings). A second, separate SQLite file — *not* part of the artifact database. | `RagIndex` rebuilds. |
| `last_recommendation_trace.txt` | The most recent LLM recommendation exchange (debugging aid; overwritten each round). | The UI auto-tune loop. |

[Round snapshots](@ref gloss_round_snapshot) are *not* separate files —
they're stored inside the `.emu`, capped at 100 by default.

## The repo-local config: `resect.config`

A key=value file at the repository root, shared by `install.sh`, `run.sh`,
and the app's System Configuration dialog. It holds machine-local paths and
toggles: the Flutter and engine directories, the Renode binary and port,
objdump paths, module enables (`MODULE_GHIDRA`, LLM host/model), and log
locations. It's the reason scripts and app agree on where things are.

## Managed tool installs: `~/.local/share/resect/`

When you enable modules from the System Configuration dialog, their
runtimes are installed here (Ghidra plus a managed JRE; Ollama uses its own
installer). Nothing else of Resect's lives there.

## Scratch and logs: `/tmp`

Ephemeral, safe to delete: `/tmp/renode_logs` (Renode output; path
configurable in `resect.config`) and `/tmp/resect_hook_*` (hook test
harness and progress-runner work dirs).

## Exports

Deliverables you explicitly create from the Publish tab (or `cli export`)
land wherever you point the save dialog: a project bundle `.zip`, a
standalone Renode `.resc` script, or a self-contained Vagrant bundle.

## In short

One config root holds the two models (`artifacts.db` and `projects/`);
each saved project accumulates manifests, auto-tune reports, and a RAG
index beside it; `resect.config` pins machine-local paths; `/tmp` is
disposable.
