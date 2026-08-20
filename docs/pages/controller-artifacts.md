# The ArtifactController {#controller_artifacts}

This page is the specification of the
[controller](@ref gloss_controller) for
[model #1](@ref model_artifacts) — the single class through which
[hooks](@ref gloss_hook) are generated, stored, queried, associated with
symbols, and shared.

@note **Deviation from the current code.**
**Today:** this controller does not exist as one class. Its closest
ancestor is `ArtifactLibraryService`
(`emulator_orchestrator/lib/services/hooks/artifact_library_service.dart`),
which wraps the database and owns firmware registration and template
seeding — but two dialogs (`hook_database_dialog.dart`,
`llm_hook_gen_dialog.dart`) run their own SQL against `ArtifactDatabase`,
and the generate-and-bind sequence is written out twice
(`AutoTuneEngine._generateAndSeedCustomHooks`,
`SynthesizerWorkflow._tryLlmFallback`).
**Planned:** @ref phase_p3 promotes the service to `ArtifactController`
with the surface below and folds the duplicates into
`generateAndBind`.
**Why:** copies of the same insert-and-bind logic have already
drifted once and must be fixed in every location every time; and with
dialogs running raw SQL, nothing enforces dedup-on-insert or import
inlining uniformly.

## The job

`ArtifactController` is the only object that touches the
[artifact database's](@ref gloss_artifact_db) hook rows. Every caller — the
Hook Database dialog, the LLM generation dialog, the
[synthesizer](@ref gloss_synthesizer), the [auto-tune](@ref gloss_autotune)
engine, the CLI — goes through it. It lives in the `emulator_orchestrator`
package (plain Dart, no Flutter), so the UI and CLI share one
implementation.

Its surface is five verbs.

## The five verbs

### 1. Generate

Author a new hook body with the LLM:

    Stream<LlmStreamEvent> generateHook({userPrompt, targetSymbol, elfHash})

Wraps the existing `LlmHookGenerator`: try the deterministic
[classifier](@ref gloss_classifier) first (no LLM needed if a rule
matches), otherwise compose a [RAG](@ref gloss_rag)-augmented prompt from
the firmware's [Ghidra facts](@ref gloss_ghidra_extraction) and stream the
generation. Streaming is not optional — callers show tokens as they arrive.

### 2. Store

Plain CRUD on the hook pool: `addHook`, `updateHookBody`, `deleteHook`,
`setIntrinsicScore`. Dedup-on-insert and import-inlining (described in
@ref model_artifacts) happen here, so no caller can store a malformed row.

### 3. Query

`listHooks`, `getHook(id)`, `findHookByBody`, `templates()`, plus the
firmware-fact lookups the service already owns (`lookupFirmware`,
signature/decompilation reads).

### 4. Associate (bind)

The verb that connects model #1 to model #2 — carefully:

    Future<HookBinding> bindHook({symbol, artifactId, fidelity, provenance, scope})
    Future<HookBinding> generateAndBind({symbol, intent, elfHash, provenance})
    Future<Map<String, HookBinding>> seedClassifierBindings(elfHash)

`generateAndBind` consolidates the two near-identical copies of the same
sequence — generate a hook, store it as a `user` artifact, seed a
[binding](@ref gloss_binding) at fidelity 0.5 — that exist today (listed
in [Gap 2](@ref gap_artifact_controller)). `seedClassifierBindings` wraps the
existing `HookBindingSeeder` bulk pass.

**The rule:** these methods *return* `HookBinding` values. They never write
a `.emu` file. Persisting the binding into the project is the caller's job,
via @ref controller_projects. This is the
[bodies-vs-associations rule](@ref bodies_vs_associations) made mechanical
— if you add a method to this controller that writes project state, you've
broken the architecture.

### 5. Share

Hooks are meant to travel between installs and teammates:

    Future<String> exportHooks(List<int> ids)   // portable JSON
    Future<List<int>> importHooks(String json)  // returns new row ids

plus the existing `checkRemoteLibrary()` stub, kept as the seam where a
shared remote library will attach later.

## Maintenance duties

The controller keeps the promoted service's housekeeping, because the
database must be self-healing across versions: `ensureDefaultTemplates`
(seed the catalog on first run), `ensureIntrinsicScores`,
`migrateLegacyHookBodies`, `reseedDefaults`, and `processElfFile` (hash,
register, and seed a newly imported firmware).

## What callers look like after phase P3

The Hook Database dialog stops importing `ArtifactDatabase` and calls
`store`/`query` verbs. The LLM generation dialog becomes a view over
`generateHook`. The synthesizer's [LLM fallback](@ref gloss_llm_fallback)
and the auto-tune engine's custom-hook step both become one-line calls to
`generateAndBind`. The dialogs shrink; the behavior doesn't change.

## In short

One plain-Dart class, five verbs — generate, store, query, bind, share —
promoted from the existing `ArtifactLibraryService`. It is the only writer
of hook rows, it returns bindings instead of persisting them, and it
replaces two duplicated generate-and-bind implementations with one.
