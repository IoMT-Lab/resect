# Storage Map: What Resect Writes Where {#storage_map}

Everything Resect persists, in one place. When you're debugging "where did
that come from?", start here. The paths below are the same in a container —
they just land in a volume instead of your home directory; see
[the container mapping](@ref storage_containers) at the end.

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
| `autotune_reports/<timestamp>/` | Per-[round](@ref gloss_round) reports from an auto-tune session: `round_NN.md` (outcome, metrics, frontier, decisions, recommendations + rationales), `round_NN_manifest.json`, `round_NN_trace.txt` (the exact prompt sent, plus thinking and raw response), `summary.md`. Reading them: @ref autotune_decisions. | The report [sink](@ref gloss_sink) — **both** the CLI and UI sessions. |
| `rag_index.db` | The per-project [RAG](@ref gloss_rag) index (chunked documents + embeddings). A second, separate SQLite file — *not* part of the artifact database. | `RagIndex` rebuilds. |

[Round snapshots](@ref gloss_round_snapshot) are *not* separate files —
they're stored inside the `.emu`, capped at 100 by default.

## The repo-local config: `resect.config`

A key=value file at the repository root, shared by `install.sh`, `run.sh`,
and the app's System Configuration dialog. It holds machine-local paths and
toggles: the Flutter and engine directories, the Renode **server** host and
port (`RENODE_HOST`/`RENODE_PORT`) plus the portable binary used by the
hook-quality harness, objdump paths, module enables (`MODULE_GHIDRA`,
`MODULE_LLM_HOOKGEN`), the Ollama host and model, and log locations. It's the
reason scripts and app agree on where things are.

In a container this file is baked into the image at `/resect.config` and
selected by the `RESECT_CONFIG` environment variable — see
@ref containers for the shipped values.

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

## In a container {#storage_containers}

Nothing about the paths changes — what changes is what they resolve to. The
image's entrypoint symlinks the container user's `$HOME/.config` to
`/static_home`, which is the `resect-state` volume:

| Path inside the container | Backed by |
|---|---|
| `~/.config/call_graph_viewer/artifact_library/artifacts.db` | `resect-state` volume (survives container removal) |
| `~/.config/call_graph_viewer/projects/` | `resect-state` volume |
| `/workdir` — the working directory | `./workdir` bind mount, visible on the host |
| Ollama model weights | `ollama-models` volume |

So the [artifact database](@ref gloss_artifact_db) persists across runs and
across the container's cli/gui/vnc modes, while anything you want to read on
the host — projects, manifests, auto-tune reports — belongs under
`/workdir`. Two scripts delete this state: `scripts/clean.sh` **empties the
`resect-state` volume** (app data, keeping the model cache), and
`scripts/uninstall.sh` runs `docker compose down -v` and **removes both
volumes entirely**.

## In short

One config root holds the two models (`artifacts.db` and `projects/`);
each saved project accumulates manifests, auto-tune reports, and a RAG
index beside it; `resect.config` pins machine-local paths; `/tmp` is
disposable. In a container, the config root is the `resect-state` volume and
your working files live in the `./workdir` bind mount.
