# Current vs. Target {#current_vs_target}

@ref architecture describes where Resect is going. This page is the honest
inventory of where the code differs from that picture today, so nobody is
surprised when they open a file and find something messier than the diagram.
Each gap links to the @ref roadmap phase that closes it. When a phase
lands, delete its gap from this page — when every gap is closed, this page
should be empty. (Individual pages also carry "Deviation from the current
code" notes at the exact spot where the design and the code differ; this
page is the collected index of them.)

All file paths are relative to the repository root. Line counts and
locations were verified against the source when this page was written
(July 2026).

## Gap 1 — The project has no controller {#gap_project_controller}

The [project's](@ref gloss_project) lifecycle logic is scattered across the
UI instead of living in one controller:

- Create/open/save/close are **free functions** in
  `emulator_ui/lib/presentation/screens/library/library_actions.dart`
  (~657 lines), which also embed real policy — binding backfill and
  classifier seeding on open.
- The open project is mirrored into roughly **eight "shadow" Riverpod
  providers** (`hookOverridesProvider`, `hookPreferencesProvider`,
  `hookOverrideScopesProvider`, `hookBindingsProvider`,
  `executedSymbolsProvider`, `synthesisResultProvider`,
  `lastRunInsightProvider`, `hookedSymbolsProvider` in
  `emulator_ui/lib/providers/app_providers.dart`) that duplicate fields of
  the one `Emulator` object. An `AutosaveController`
  (`emulator_ui/lib/providers/autosave_provider.dart`) exists mostly to
  shuttle state between the two representations.
- There are **two separate restore paths** that must agree: the one in
  `library_actions.openEmulator` and a second in the
  `EmulatorChangedEvent` listener inside `app_providers.dart`.
- The CLI doesn't use any of this — it mutates the `Emulator` object
  directly.

Target: one @ref controller_projects holding one `Emulator`, one restore
path, no shadow providers. Closed by roadmap phases @ref phase_p2 (single
restore path) and @ref phase_p5 (the controller and provider collapse).

## Gap 2 — The artifact database has no controller {#gap_artifact_controller}

Nothing stands between callers and the raw
[artifact database](@ref gloss_artifact_db):

- Two giant dialogs do their own database CRUD:
  `emulator_ui/lib/presentation/dialogs/hook_database_dialog.dart`
  (~1850 lines) and `llm_hook_gen_dialog.dart` (~1277 lines).
- The "generate a hook with the LLM, store it, and seed a binding" sequence
  is written out **twice**:
  `AutoTuneEngine._generateAndSeedCustomHooks`
  (`emulator_orchestrator/lib/orchestrator/auto_tune_engine.dart`) and
  `SynthesizerWorkflow._tryLlmFallback`
  (`emulator_orchestrator/lib/orchestrator/workflows/synthesizer_workflow.dart`).
  (A third copy in the UI's old auto-tune loop was deleted when the UI
  adopted the engine.)

Target: the five-verb @ref controller_artifacts, with the triplicated logic
folded into one `generateAndBind`. Closed by roadmap phase @ref phase_p3.

## Gap 5 — Layering leaks {#gap_layering}

Small but real violations of the intended
models → services → orchestrator layering:

- `emulator_orchestrator/lib/data/models/trace_activity_event.dart` imports
  `orchestrator/engine/paused_event.dart` — a data model reaching *up* into
  the orchestrator.
- `emulator_orchestrator/lib/data/models/auto_tune_config.dart` imports
  `services/llm/recommendation_service.dart` just to get the
  `OptimizationTarget` enum, which lives in the wrong file.

Closed by roadmap phase @ref phase_p1.

## Gap 6 — Business logic inside widgets {#gap_widget_logic}

Beyond the two dialogs in Gap 2, several widgets run multi-service
workflows inline: `last_run_card.dart` drives a streaming LLM session from
widget state; `graph_viewer_widget.dart` contains the call-graph
regeneration and cache-invalidation flow; `metadata_panel.dart` writes
[overlay](@ref gloss_overlay) providers directly; `comms_screen.dart`
implements its call-tree construction algorithm in the screen file. Target:
widgets call controller/orchestrator methods and render state, nothing
else. Closed by roadmap phase @ref phase_p6.

## Known debts, acknowledged but not scheduled {#known_debts}

These are recorded so they aren't forgotten, but no roadmap phase covers
them yet:

- Four data services import `package:renode` directly (`hooks/hook_catalog`,
  `hooks/hook_classifier`, `quality/hook_test_harness`,
  `quality/hook_progress_runner`) — the "only the engine layer talks to
  Renode" boundary leaks. They are genuinely engine-bound; revisit only if a
  second engine becomes real.
- The two [call-graph](@ref gloss_call_graph) sources are wired unevenly.
  The UI picks per config (`callGraphSourceProvider` in
  `emulator_ui/lib/providers/app_providers.dart`): `GhidraCallGraphSource`
  (`emulator_orchestrator/lib/orchestrator/engine/dart/ghidra_call_graph_source.dart`)
  when the Ghidra module is enabled and configured, the objdump-based
  `DartCallGraphSource` otherwise. The CLI is hard-wired to the objdump
  source — so the UI and the CLI can produce different call graphs for the
  same project.
- **The headless path has no annotation layer.** The
  [classifier](@ref gloss_classifier) binding-seed pass runs only from the
  UI's project-open path (`_seedClassifierBindings` in
  `emulator_ui/lib/presentation/screens/library/library_actions.dart`), and
  the [container](@ref containers) images ship no Ghidra, no `GHIDRA_DIR`,
  and no `MODULE_GHIDRA`. So the surface that runs unattended for dozens of
  [rounds](@ref gloss_round) is the one reasoning with the least
  information — no decompiled bodies, no classifier
  [bindings](@ref gloss_binding), no frontier annotations. Detail in
  @ref pre_synthesis; the open question is how Ghidra becomes available in
  the container path (bake it into the image, install it into the volume, or
  pre-extract on the host).
- **Per-symbol hook candidates aren't filtered.**
  `ArtifactDatabase.getArtifactsForSymbolByName(elfHash, symbol)` ignores
  both arguments and returns `getAllArtifacts()`, so every symbol's
  candidate list is the whole catalog, ranked only by score
  (@ref pre_synthesis).
- **[Auto-tune](@ref gloss_autotune) keeps no best-so-far anchor.** Overlays
  are cumulative and mutated in place with no revert, so a session that
  peaks mid-run and then regresses finishes holding its last result rather
  than its best one. `RoundSnapshot` already records per-round metrics, so
  the comparison data exists (@ref autotune_decisions).

## In short

Four gaps stand between today's code and the
[architecture](@ref architecture): no project controller, no artifact
controller, two layering leaks, and business logic in widgets. (The
duplicated auto-tune loop and the triplicated fidelity math are closed —
both surfaces now drive one engine and one enrichment path.) Every
remaining gap has a scheduled phase in the @ref roadmap. This page shrinks
as they land. The known debts below it are unscheduled, and the biggest of
them is that the headless surface runs without the annotation layer.
