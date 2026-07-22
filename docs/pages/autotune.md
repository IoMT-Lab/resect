# Auto-tune: The Closed Loop {#autotune}

A single @ref synthesis run gets the firmware to *complete*.
[Auto-tune](@ref gloss_autotune) is the loop that tries to make it complete
*well*: run synthesis, show the results to an LLM, apply the changes it
recommends, run again — until [fidelity](@ref gloss_fidelity) stops
improving or a limit is hit. This page describes the engine, its two
pluggable seams, and how the UI and CLI drive it.

## One engine

The loop is implemented once, in `AutoTuneEngine`
(`emulator_orchestrator/lib/orchestrator/auto_tune_engine.dart`) — plain
Dart, no Flutter, no Riverpod.

@note **Deviation from the current code.**
**Today:** only the CLI drives `AutoTuneEngine`. The UI's Auto-tune button
runs a separate, older copy of the loop — `LlmSynthesisOrchestrator`
(`emulator_ui/lib/presentation/screens/synthesize/llm_synthesis_orchestrator.dart`)
— which lacks the [stagnation](@ref gloss_stagnation) guard, the no-op
recommendation filter, the escalation feedback, and the per-round
recommendation cap described below (details in
[Gap 3](@ref gap_two_loops)).
**Planned:** @ref phase_p4 drives the engine from the UI through an
interactive review policy and deletes the copy.
**Why:** a UI session can spend all its rounds on stagnant coverage that a
CLI session would detect and stop early, and every loop improvement must
currently be written twice or the two drift.

## A round, step by step

After a baseline synthesis run (or a seeded baseline from a fresh
[round snapshot](@ref gloss_round_snapshot), so the session doesn't repeat
work), each [round](@ref gloss_round) goes:

1. **Recommend.** `RecommendationService` sends the LLM the round's
   context — the [manifest](@ref gloss_manifest), the overlay state, the
   artifact catalog, fidelity deltas, and any escalation feedback — and
   constrained decoding forces the reply into typed
   [recommendations](@ref gloss_recommendation): set/clear an
   [override](@ref gloss_override), set a
   [preference](@ref gloss_preference), generate a custom hook, or adjust
   the iteration cap.
2. **Review.** The [review policy](@ref gloss_review_policy) decides each
   recommendation's fate (see "Two seams" below).
3. **Filter no-ops.** Accepted recommendations that are already in effect
   are dropped; a round where *everything* was a no-op counts as stagnant.
4. **Author.** Accepted generate-custom-hook recommendations produce new
   artifacts and [bindings](@ref gloss_binding) (one of the three
   duplicated sites that @ref controller_artifacts consolidates).
5. **Apply.** The surviving recommendations mutate the
   [overlays](@ref gloss_overlay) through the one shared applier
   (`applyRecommendationsToOverlays`).
6. **Re-run synthesis** with the updated overlays; enrich the result with
   fidelity metrics.
7. **Snapshot.** Persist a [round snapshot](@ref gloss_round_snapshot) —
   overlays, metrics, recommendations, decisions — onto the project.
8. **Check the guards** (below), then loop.

## The guards, and how a session ends

Two progress detectors (shared in `auto_tune_progress.dart`) stop the loop
from wasting rounds:

- **No progress on a symbol:** consecutive rounds failing at the same
  symbol with nothing new to try.
- **[Stagnation](@ref gloss_stagnation):** successful rounds reproducing
  the exact same [executed-symbol](@ref gloss_executed_symbols) set (or
  all-no-op rounds) for `stagnantRoundLimit` consecutive rounds. Before
  giving up, the engine escalates: it computes the coverage
  [frontier](@ref gloss_frontier) and feeds the stalled caller functions
  back into the next recommendation prompt as explicit targets.

Every ending is a named `AutoTuneStopReason`: `baselineFailed`,
`parseFailed`, `llmEmpty`, `userStopped`, `userRejectedAll`,
`noProgressOnSymbol`, `noCoverageProgress`, `cancelled`, `maxRounds`,
`synthesisError`, `llmError`.

Session knobs live in `AutoTuneConfig`
(`emulator_orchestrator/lib/data/models/auto_tune_config.dart`); defaults:
5 max rounds, 10 recommendations per round, stagnant-round limit 2,
snapshot cap 100.

## Two seams: review policy and sink

The engine takes no UI dependency because the two places a UI could appear
are injected interfaces:

- **[Review policy](@ref gloss_review_policy)** — who judges the
  recommendations. The CLI plugs in `AcceptAllReviewPolicy`; the UI plugs
  in an interactive policy that pauses the loop while you accept, reject,
  or edit each recommendation in the auto-tune modal.
- **[Sink](@ref gloss_sink)** — where progress goes. The CLI's
  `AutoTuneReportSink` writes per-round files (`round_NN.md`,
  `round_NN_manifest.json`, `round_NN_trace.txt`, `summary.md` — see
  @ref storage_map); the UI's sink feeds the modal's state.

Same engine, same rounds, same guards — different policy and sink. That's
the whole difference between `resect-cli autotune` and clicking
**Auto-tune** in the Synthesize tab.

## Reading a session afterwards

Ask three questions, in order: What was the coverage-fidelity trajectory
across rounds (`summary.md` or the snapshots)? Which recommendations were
applied each round, and did the round after them improve? Why did it stop —
`maxRounds` means the session used its full round budget;
`noCoverageProgress` means the loop had no further changes to try.

## In short

One plain-Dart engine: recommend → review → filter → author → apply →
re-synthesize → snapshot, with no-progress and stagnation guards and named
stop reasons. The CLI and the UI differ only in which review policy and
sink they inject. (Today's UI still runs its own lagging copy — phase
@ref phase_p4 fixes that.)
