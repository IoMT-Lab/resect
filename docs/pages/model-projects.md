# Model #2: The Project {#model_projects}

This page describes the second of Resect's two data
[models](@ref gloss_model): the [project](@ref gloss_project) — one
firmware re-hosting effort, saved as a single `.emu` file. For the
controller that manages it, see @ref controller_projects.

## What it is

A project is everything you'd want to hand a teammate so they can pick up
your re-hosting work: which firmware, which platform, which
[hooks](@ref gloss_hook) go where, what happened on previous runs. In code
it is the class [Emulator](@ref gloss_emulator_model)
(`emulator_orchestrator/lib/data/models/emulator.dart` — the class name is
historical; these docs say "project"). On disk it is one pretty-printed
JSON file with the `.emu` extension, written by `EmulatorRepository`
(`emulator_orchestrator/lib/data/repositories/emulator_repository.dart`),
by convention under `~/.config/call_graph_viewer/projects/`.

There is no database involved. A `.emu` file is self-describing, diffable,
and portable — you can read one in a text editor.

## What's inside a `.emu`, field group by field group

**Identity and inputs.** `id`, `name`, timestamps, `elfFilePath` (the
firmware binary), `baseImagePath` (the Renode `.repl` platform
description), and `emulationConfig` — where a run starts (`startFrom`),
where it stops (`endAt`), whether to pause on
[unhandled accesses](@ref gloss_unhandled_access), and an optional
memory-map file (`memoryMapPath`, JSON key `memory_map`).

**The hook [overlays](@ref gloss_overlay).** The per-symbol hook decisions
specific to this project: `hookOverrides` (symbol →
artifact id, forced), `hookOverrideScopes` (symbol →
[scope](@ref gloss_scope)), `hookPreferences` (symbol → artifact id,
soft), `hookBindings` (symbol → [binding](@ref gloss_binding)), and
`groupOverrides` ([group scope](@ref gloss_group_scope) →
`GroupOverrideState`, JSON key `group_overrides`) — the per-group
force/suppress decisions written by the auto-tune LLM's group actions
(@ref symbol_groups). What each map means and which wins is its own page:
@ref hook_overlays.

**Warm-start hooks.** `hooks` — symbol → the resolved Python code from the
last successful run, pre-seeded into the next one
([warm start](@ref gloss_warm_start)).

**Comms.** `commsAssignments` — symbol →
[comms class](@ref gloss_comms_class) and read/write role, feeding
@ref comms_virtualization.

**Results and history.** `synthesisResult` (the last run's outcome and
[manifest](@ref gloss_manifest)), `executedSymbols`, `lastRunInsight` (a
cached LLM advisory), and `roundSnapshots` — the list of
[round snapshots](@ref gloss_round_snapshot) from
[auto-tune](@ref gloss_autotune) sessions, capped by `roundSnapshotCap`
(JSON key `round_snapshot_cap`; default 100, oldest pruned first).

**UI state and caches.** `cachedCallGraph` (so reopening a project doesn't
re-extract the [call graph](@ref gloss_call_graph) — but reuse is
conditional: the graph carries the SHA-256 of its source ELF in
`CallGraph.elfHash` (`data/models/call_graph.dart`), `openEmulator` strips
a graph whose stamp doesn't match the project's firmware,
`callgraphProvider` reuses the cache only on a content-hash match, and an
unstamped graph from a pre-stamp `.emu` always regenerates), `documents`
(notes and datasheets attached to the project), `uiState` (sidebar
expansions, selected symbol — so the app reopens where you left off), and
`metadata` (an open-ended map reserved for future expansion).

## What is deliberately NOT in a `.emu`

Hook *bodies*. An overlay stores artifact **ids**; the Python they point to
lives in the [artifact database](@ref gloss_artifact_db). That's the
[bodies-vs-associations rule](@ref bodies_vs_associations). (The one
pragmatic exception is the warm-start `hooks` map, which stores resolved
code so a finished project can be exported and re-run as-is.)

## Files that orbit the project

A saved project accumulates sibling directories next to (or named for) its
`.emu` file — per-run [manifests](@ref gloss_manifest), auto-tune reports,
attached documents, and a per-project [RAG](@ref gloss_rag) index. The full
disk picture, including exactly which path each of these uses, is in
@ref storage_map.

## In short

A project is one `.emu` JSON file: firmware + platform paths, the five
overlay maps, comms assignments, results, and history. It references hook
bodies by id but never contains them. It's the unit you save, reopen, share,
and export.
