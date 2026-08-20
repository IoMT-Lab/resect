# Roadmap {#roadmap}

The ordered plan for closing the gaps between today's code and the
@ref architecture. Each phase is independently shippable and testable —
one phase, one PR. As items land, flip their ☐ to ☑ here and delete the
corresponding gap from @ref current_vs_target.

Sizes: **S** = hours, **M** = a day or two, **L** = a week-scale change.

## Phase P1 — Mechanical cleanups (S–M) {#phase_p1}

Zero behavior change; existing tests must stay green untouched.

- ☑ Route all [fidelity](@ref gloss_fidelity)-enrichment call sites
      through the one shared helper (`enrichSynthesizerResult` /
      `enrichManifestWithMetrics` in `auto_tune_engine.dart`). Closed
      Gap 4; the UI report card now renders `manifest.metrics` too.
      (The UI-loop call site was deleted with phase P4; the live sites
      are `synthesis_controller.dart`, the CLI's `synthesize` and
      `autotune`, and `api_server.dart`.)
- ☐ Move the `OptimizationTarget` enum into `auto_tune_config.dart`;
      drop the model → service import.
- ☐ Stop `trace_activity_event.dart` importing the orchestrator layer
      (move or mirror `PausedEvent` appropriately). With the previous
      item, closes [Gap 5](@ref gap_layering).

## Phase P2 — Single restore path (M) {#phase_p2}

- ☐ Make `openEmulator`'s restore sequence the only one; delete the
      duplicate restore block in the `EmulatorChangedEvent` listener in
      `emulator_ui/lib/providers/app_providers.dart`.
- ☐ Verify open/save round-trips via the existing tests plus a manual
      open-project pass in the UI.

First half of [Gap 1](@ref gap_project_controller); prepares
@ref phase_p5.

## Phase P3 — ArtifactController (M) {#phase_p3}

Build the [ArtifactController](@ref controller_artifacts):

- ☐ Promote `ArtifactLibraryService` → `ArtifactController` under
      `emulator_orchestrator/lib/orchestrator/`; add the five-verb surface
      (generate, store, query, bind, share).
- ☐ Fold the two remaining duplicated generate-and-bind sites into
      `generateAndBind` (the sites are listed in
      [Gap 2](@ref gap_artifact_controller); the UI loop's third copy
      died with phase P4).
- ☐ Point `hook_database_dialog.dart` and `llm_hook_gen_dialog.dart` at
      the controller instead of raw `ArtifactDatabase`.
- ☐ Unit tests for `generateAndBind` and the bind verbs.

## Phase P4 — One auto-tune loop (M–L) — DONE {#phase_p4}

Closed Gap 3; the behavior is @ref autotune.

- ☑ Write `UiReviewPolicy` (interactive
      [review policy](@ref gloss_review_policy); lifted the Completer-based
      pause/resume from the old UI loop; also carries the accept-all mode
      chosen at session start).
- ☑ Write `UiAutoTuneSink` mapping engine events to the auto-tune
      session view's state types; persist
      [round snapshots](@ref gloss_round_snapshot) through the project.
- ☑ Drive `AutoTuneEngine` from the Auto-tune button; pass
      `seedBaseline` where the UI previously skipped the baseline. UI
      sessions also run an `AutoTuneReportSink` (via `MultiSink`) so both
      surfaces write the same report files.
- ☑ Add session-view copy for engine-only stop reasons (notably
      `noCoverageProgress`).
- ☑ Delete the UI loop body and the UI-side `RecommendationApplier`;
      tests migrated to engine + policy + sink tests.
      (`LlmSynthesisOrchestrator` survives as a thin adapter — same name
      and public surface, zero loop logic — so the session UI and its
      tests, today `auto_tune_panel_test.dart` /
      `auto_tune_session_view_test.dart`, were untouched.)

UX changes shipped with it: no-op recommendations get filtered, sessions
can end early with `noCoverageProgress`, cold-start rounds are the default
(warm start is a knob), and comms virtualization defaults now match the CLI.

## Phase P5 — ProjectController (L, highest risk) {#phase_p5}

Finish [Gap 1](@ref gap_project_controller); the target is
@ref controller_projects.

- ☐ Rename `EmulatorWorkflow` → `ProjectController`; absorb the
      lifecycle + seeding logic from `library_actions.dart` (file pickers
      and snackbars stay UI-side).
- ☐ Introduce `currentProjectProvider` as a `Notifier` over an
      **immutable** `Emulator` (mutations via `copyWith` — this is the
      detail that breaks the UI if done wrong: in-place mutation silently
      stops `select()` rebuilds from firing).
- ☐ Shim first: re-express the eight shadow providers as read-only
      projections of the one provider; migrate widgets to `select()`
      incrementally; delete the shim last.
- ☐ Delete `AutosaveController.gatherState`/`restoreArtifacts`; keep a
      debounced `save()` preserving the "never-saved projects skip
      autosave" gate.
- ☐ Convert the CLI's direct `Emulator` mutations to controller calls.

## Phase P6 — Slim the widgets (M, spread over time) {#phase_p6}

Close [Gap 6](@ref gap_widget_logic), one widget at a time, now that the
controllers exist: `last_run_card` (move the streaming insight session
behind a controller), `graph_viewer_widget` (call-graph regeneration flow),
`metadata_panel` (overlay writes through @ref controller_projects),
`comms_screen` (extract the tree-building algorithm), and the remaining
logic in the two big dialogs.

## Landed outside the phases

- ☑ Cached [call graphs](@ref gloss_call_graph) are bound to their
      firmware by SHA-256 stamp (`CallGraph.elfHash`, validated through
      `call_graph_guard.dart`); a mismatched or unstamped cache is logged
      and regenerated (commit 12478c1).
- ☑ The blocking auto-tune modal was replaced by an inline panel in the
      Synthesize tab (`AutoTunePanel` / `AutoTuneSessionView`), so trace
      activity and results stay visible while a session runs
      (commit 7eb8d98).

## Deliberately out of scope

Recorded in [known debts](@ref known_debts): the four `package:renode`
imports in data services, and `GhidraCallGraphSource` being wired unevenly
(the UI selects it by configuration; the CLI is objdump-only). The
hooks→renode pin conflict is resolved — the engine packages resolve as
hosted locked versions with no active override. Also deferred: the
escalation-authoring improvement to auto-tune (tracked in `TODO.txt`).

## In short

Six phases, smallest risk first: mechanical dedup, one restore path, the
artifact controller, one auto-tune loop, the project controller (behind a
shim), then widget slimming. Each phase is a PR; each deletes a section of
@ref current_vs_target.
