# Model #1: The Artifact Database {#model_artifacts}

This page describes the first of Resect's two data
[models](@ref gloss_model): the
[artifact database](@ref gloss_artifact_db) — what's in it, how it's keyed,
and what deliberately is *not* in it. For the controller that manages it,
see @ref controller_artifacts.

## What it is

One SQLite database, global to your machine, at:

    ~/.config/call_graph_viewer/artifact_library/artifacts.db

It is defined with the Drift package in
`emulator_orchestrator/lib/data/database/artifact_database.dart` (class
`ArtifactDatabase`, schema version 9, with migrations back to the earliest
installs). Both the UI and the CLI open this same file.

The database answers two questions:

1. **"What hook bodies do we have?"** — the [artifact](@ref gloss_artifact)
   pool, shared by every project.
2. **"What do we know about this firmware?"** — facts extracted from a
   binary, cached so they're computed once, keyed by
   [ELF hash](@ref gloss_elf_hash).

## The hook pool

The `Artifacts` table is the heart of the model. Each row is one reusable
[hook](@ref gloss_hook) body:

| Column | Meaning |
|---|---|
| `artifactData` | The Python source of the hook. |
| `artifactType` | What kind of artifact this is (today: `renode_hook`). |
| `origin` | `default` = seeded from the built-in catalog; `user` = authored in this install (by a person *or* by the LLM). |
| `name` | Optional human-readable label. |
| `architecture` | `ARM`, `x86_64`, or null when the body is arch-neutral. |
| `targetSymbolName` | Non-null means "this is a replacement written for one specific function," e.g. an LLM-authored model of `bmp180_read_temp`. Null means it's a generic template. |
| `intrinsicScore` | The [intrinsic score](@ref gloss_intrinsic_score): a 0.0–1.0 suitability floor used to rank candidates when no project [binding](@ref gloss_binding) exists. |

Bodies are deduplicated on insert (`findArtifactByBody`), and any
`import`-style references are inlined at write time so a stored body is
always self-contained.

## The firmware facts

The rest of the tables cache what Resect has learned about each firmware
binary, keyed by its [ELF hash](@ref gloss_elf_hash) so the cache survives
file renames and moves:

- **`FirmwareImages`** — every firmware Resect has indexed: hash, file
  name, ELF machine type, when it was registered.
- **`Symbols`** — the function names found in each firmware.
- **`Signatures`, `GhidraCallGraphs`, `GhidraDecompilations`,
  `GhidraDataTypes`, `GhidraDataSymbols`, `GhidraMemoryMap`** — the six
  tables filled by a [Ghidra extraction](@ref gloss_ghidra_extraction)
  pass: per-function signatures, the full call graph, decompiled C
  pseudocode, struct/typedef layouts, named globals, and the memory map.
  These power the [classifier](@ref gloss_classifier), LLM prompts, and
  [RAG](@ref gloss_rag) retrieval.

A worked example of why this matters: when the comms layer needs to know
whether `get_i2c` is a real bus-transfer function or just a zero-argument
accessor, it looks up the function's cached signature and counts parameters
— a fact that only exists because the extraction pass stored it here. (See
@ref comms_virtualization for that story.)

## What is deliberately NOT in this database

Per the [bodies-vs-associations rule](@ref bodies_vs_associations), the
database never stores *which project uses which hook where*. Overrides,
preferences, bindings, comms assignments, results, and history all live in
the [project](@ref gloss_project) — see @ref model_projects. If two
projects re-host the same firmware, they share every row in this database
and still make completely independent hook choices.

## In short

One global SQLite file with two kinds of content: a deduplicated pool of
hook bodies (the `Artifacts` table) and cached per-firmware facts keyed by
ELF hash (everything else). No per-project opinions live here — those
belong to model #2.
