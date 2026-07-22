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
  is written out **three times**:
  `AutoTuneEngine._generateAndSeedCustomHooks`
  (`emulator_orchestrator/lib/orchestrator/auto_tune_engine.dart`),
  `LlmSynthesisOrchestrator._generateAndSeedCustomHooks`
  (`emulator_ui/.../llm_synthesis_orchestrator.dart`), and
  `SynthesizerWorkflow._tryLlmFallback`
  (`emulator_orchestrator/lib/orchestrator/workflows/synthesizer_workflow.dart`).

Target: the five-verb @ref controller_artifacts, with the triplicated logic
folded into one `generateAndBind`. Closed by roadmap phase @ref phase_p3.

## Gap 3 — Two auto-tune loops {#gap_two_loops}

The [auto-tune](@ref gloss_autotune) loop exists twice:

- The engine: `AutoTuneEngine`
  (`emulator_orchestrator/lib/orchestrator/auto_tune_engine.dart`) —
  UI-agnostic, pluggable [review policy](@ref gloss_review_policy) and
  [sink](@ref gloss_sink). **Used only by the CLI.**
- The UI's own copy: `LlmSynthesisOrchestrator`
  (`emulator_ui/lib/presentation/screens/synthesize/llm_synthesis_orchestrator.dart`)
  — a `ChangeNotifier` wired directly to Riverpod. It **lags the engine**:
  no [stagnation](@ref gloss_stagnation) guard, no no-op recommendation
  filtering, no escalation feedback, no per-round recommendation cap.

So a UI auto-tune session can churn to `maxRounds` on stagnant coverage
where a CLI session stops early with `noCoverageProgress`. The two share the
recommendation-apply step (`recommendation_overlay_applier.dart`) but
nothing else. Target: the UI adopts the engine with an interactive review
policy; the UI copy is deleted. Closed by roadmap phase @ref phase_p4.

## Gap 4 — Triplicated fidelity enrichment {#gap_fidelity}

Folding [fidelity](@ref gloss_fidelity) metrics into a run result is written
out three times: `SynthesisController._enrichManifest` (UI),
`LlmSynthesisOrchestrator._recomputeMetrics` (UI), and
`enrichManifestWithMetrics` / `enrichSynthesizerResult`
(`auto_tune_engine.dart`, used by the CLI). The CLI `synthesize` command and
the HTTP API also compute fidelity inline instead of calling the shared
helper. Closed by roadmap phase @ref phase_p1.

## Gap 5 — Layering leaks {#gap_layering}

Small but real violations of the intended
models → services → orchestrator layering:

- `emulator_orchestrator/lib/data/models/trace_activity_event.dart` imports
  `orchestrator/engine/paused_event.dart` — a data model reaching *up* into
  the orchestrator.
- `emulator_orchestrator/lib/data/models/auto_tune_config.dart` imports
  `data/services/recommendation_service.dart` just to get the
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

- Four data services import `package:renode` directly (`hook_catalog`,
  `hook_classifier`, `hook_test_harness`, `hook_progress_runner`) — the
  "only the engine layer talks to Renode" boundary leaks. They are genuinely
  engine-bound; revisit only if a second engine becomes real.
- The two [call-graph](@ref gloss_call_graph) sources are wired unevenly.
  The UI picks per config (`callGraphSourceProvider` in
  `emulator_ui/lib/providers/app_providers.dart`): `GhidraCallGraphSource`
  (`emulator_orchestrator/lib/orchestrator/engine/dart/ghidra_call_graph_source.dart`)
  when the Ghidra module is enabled and configured, the objdump-based
  `DartCallGraphSource` otherwise. The CLI is hard-wired to the objdump
  source — so the UI and the CLI can produce different call graphs for the
  same project.
- A clean `dart pub get` without local sibling checkouts is blocked on a
  hooks-dart → renode-dart git-ref conflict (tracked in `TODO.txt`).

## In short

Six gaps stand between today's code and the
[architecture](@ref architecture): no project
controller, no artifact controller, a duplicated auto-tune loop, triplicated
fidelity math, two layering leaks, and business logic in widgets. Every one
has a scheduled phase in the @ref roadmap. This page shrinks as they land.
