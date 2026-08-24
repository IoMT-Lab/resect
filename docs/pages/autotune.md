# Auto-tune: The Closed Loop {#autotune}

A single @ref synthesis run gets the firmware to *complete*.
[Auto-tune](@ref gloss_autotune) is the loop that tries to make it complete
*well*: run synthesis, show the results to an LLM, apply the changes it
recommends, run again — until [coverage](@ref gloss_coverage) stops
improving or a limit is hit. This page describes the machinery: the engine,
its two pluggable seams, its stopping conditions, and how the UI and CLI
drive it. **What the LLM is shown and how it decides** is its own page:
@ref autotune_decisions.

## One engine

The loop is implemented once, in `AutoTuneEngine`
(`emulator_orchestrator/lib/orchestrator/auto_tune_engine.dart`) — plain
Dart, no Flutter, no Riverpod. It owns the mutable
[overlay](@ref gloss_overlay) maps for the session, the round counter, the
previous round's failure, the best-so-far anchor (the highest executed
count seen, the overlays that produced it, and which round it was — every
non-error exit restores the best round's overlays), and the in-memory
snapshot history it feeds back to the model. It never reads a provider;
the artifact database is its one store (authored hook bodies go in,
artifact labels and the per-round census come out) — persistence of
session state is the [sink's](@ref gloss_sink) job.

Both surfaces drive it. The CLI wires it directly; the UI's Auto-tune
button drives the same engine through a thin adapter
(`LlmSynthesisOrchestrator`, now pure wiring) that injects an interactive
review policy and a state-feeding sink. Every loop improvement lands once
and both surfaces inherit it.

## A round, step by step

Round 0 is a baseline synthesis — or a seeded baseline, when the caller
already has a fresh result to hand (the UI passes one so a session doesn't
repeat work; the CLI always synthesizes its own). Then each
[round](@ref gloss_round) goes:

1. **Recommend.** `RecommendationService` sends the LLM the round's evidence
   and constrained decoding forces the reply into typed
   [recommendations](@ref gloss_recommendation): set/clear an
   [override](@ref gloss_override), set a [preference](@ref gloss_preference),
   generate a custom hook, adjust the iteration cap, or — when a recognized
   [object group](@ref gloss_object_group) is in play — force or clear a
   whole group (`set_group_override` / `clear_group_override`; see
   @ref symbol_groups). The evidence, the framing, and the schema are
   @ref autotune_decisions.
2. **Review.** The [review policy](@ref gloss_review_policy) decides each
   recommendation's fate (see "Two seams" below). An empty recommendation
   list ends the session as converged (`llmEmpty`); a rejection of
   everything ends it as `userRejectedAll`.
3. **Dedupe.** Identical recommendations within one reply are collapsed
   before anything else — the model sometimes emits the same entry several
   times, and duplicates would burn budget slots and misreport as distinct
   moves.
4. **Refuse and warn.** One hard guard: a forced override on an entry
   point (`main`, `Reset_Handler`, `_start`) is refused outright — skipping
   an entry point deletes the program, so `kProtectedSymbols` is enforced
   here regardless of what the decoder let through. A round where *every*
   recommendation was refused counts as stagnant and escalates with the
   refusals named. Everything else that merely looks risky — a constant
   forced onto a time/counter reader, a Return-0 skip of a caller that
   executed cleanly with working hooks beneath it — draws an advisory
   warning on the round instead of a refusal; the measure-and-revert step
   below is the enforcement.
5. **Filter no-ops.** Accepted recommendations that are already in effect
   are dropped. A round where *everything* was a no-op doesn't re-synthesize
   at all — it counts as stagnant and escalates, because unchanged overlays
   would produce identical evidence.
6. **Author.** Accepted generate-custom-hook recommendations produce new
   artifacts and [bindings](@ref gloss_binding) — after a re-check that the
   target is a real call-graph symbol. (One of the two duplicated
   generate-and-bind sites that @ref controller_artifacts consolidates.)
7. **Apply.** The surviving recommendations mutate the overlays through the
   one shared applier (`applyRecommendationsToOverlays`).
8. **Re-run synthesis** with the updated overlays; enrich the result with
   fidelity metrics and executed symbols.
9. **Measure — and revert a collapse.** The engine tracks the session's
   best round (executed count plus the overlays that produced it). A round
   whose executed count falls below half the session best is rolled back
   wholesale — overlays restored to their pre-round state — and counted as
   stagnant, with the reverted moves and the measurement fed into the next
   prompt so the model doesn't repeat them.
10. **Snapshot.** Persist a [round snapshot](@ref gloss_round_snapshot) —
    overlays, metrics, executed symbols, recommendations, decisions, plus
    the round's reverted flag and warnings — onto the project, and emit the
    round report to the sink.
11. **Check the stopping conditions** (below), then loop.

## The stopping conditions

Two progress detectors (pure functions in `auto_tune_progress.dart`, shared
so the UI and CLI can't drift) stop the loop from spending rounds on
identical evidence:

- **No progress on a symbol:** this round failed at the same symbol as the
  previous one *and* nothing new was tried for it. A different symbol, or a
  new hook at the same symbol, counts as progress.
- **[Stagnation](@ref gloss_stagnation):** a successful round that reached
  no symbol the previous round hadn't (a *shrunken* set counts too). The
  first stagnant round escalates — the engine computes the coverage
  [frontier](@ref gloss_frontier) and feeds the stalled caller functions
  into the next prompt as the only permitted targets (an
  [escalation round](@ref gloss_escalation_round)). The candidates are
  filtered (entry points, already-forced symbols, and comms-covered symbols
  excluded) and ranked by how likely they contain the stall — callers on
  the recent call path that carry no hooks first, callers whose subtree
  carries working overrides last (skipping one forfeits those hooks) —
  then capped at 8. Reaching
  `stagnantRoundLimit` consecutive stagnant rounds means escalation was
  tried and didn't move coverage either, and the session stops with
  `noCoverageProgress`.

Both err toward continuing when the data is ambiguous: a session only stops
early on a positively-confirmed repeat.

Every ending is a named `AutoTuneStopReason` — `baselineFailed`,
`parseFailed`, `llmEmpty`, `userStopped`, `userRejectedAll`,
`noProgressOnSymbol`, `noCoverageProgress`, `cancelled`, `maxRounds`,
`synthesisError`, `llmError` — grouped by meaning in
@ref autotune_decisions.

Session knobs live in `AutoTuneConfig`
(`emulator_orchestrator/lib/data/models/auto_tune_config.dart`); defaults:
5 max rounds, 10 recommendations per round, stagnant-round limit 2,
3-round history window, snapshot cap 100, cold-start rounds. The
synthesizer's per-round iteration cap is separate and comes from the caller
(500 on both surfaces; the LLM's `adjust_iteration_cap` recommendation can
change it mid-session).

One knob deserves its own sentence: **warm start** (`--warm-start` on the
CLI, a switch in the UI's config dialog; default off). Cold-start rounds —
the default and the validated behavior — re-synthesize from the overlay set
on a clean machine every round, so rounds are independent, comparable
experiments. Warm start seeds each round with the previous round's resolved
hook code: faster convergence, path-dependent results.

## Two seams: review policy and sink

The engine takes no UI dependency because the two places a UI could appear
are injected interfaces:

- **[Review policy](@ref gloss_review_policy)** — who judges the
  recommendations, and whether to retry a parse failure. The CLI plugs in
  `AcceptAllReviewPolicy` (accept everything, never retry); the UI plugs in
  `UiReviewPolicy` (`emulator_ui/.../synthesize/ui_review_policy.dart`),
  chosen at session start: interactive mode pauses the loop while you
  accept, reject, or edit each recommendation in the inline auto-tune panel;
  accept-all mode behaves exactly like the CLI.
- **[Sink](@ref gloss_sink)** — where progress goes. Every phase
  transition, every streamed token, the full per-round LLM exchange, each
  round report, and the terminal reason are pushed to it. The
  `AutoTuneReportSink` writes per-round files (`round_NN.md`,
  `round_NN_manifest.json`, `round_NN_trace.txt`, `summary.md` — see
  @ref storage_map) — **both surfaces run it**, so a UI session leaves the
  same artifact trail a CLI session does. The UI additionally fans the same
  events (via `MultiSink`) into a `UiAutoTuneSink` that feeds the inline panel's
  state, persists each round's snapshot onto the project, and appends a
  compact per-round line to the panel's session strip. The Synthesize tab
  renders the session inline from that state — the auto-tune panel, a
  metric trajectory chart, and per-round compact reports — and a finished
  session is rehydrated from disk on project reopen
  (`services/analysis/autotune_session_loader.dart` reads the newest report
  directory's round manifests and rejoins them with the project's
  snapshots).

Same engine, same rounds, same stopping conditions — different policy and
sink. That's the whole difference between `resect-cli autotune` and clicking
**Auto-tune** in the Synthesize tab.

## Driving it headlessly

    resect-cli autotune --emu example/aya.emu --max-rounds 10

That one command builds the whole stack the UI builds: engine lifecycle,
call graph (the project's cached one when its SHA-256 stamp matches the
firmware being emulated — a stale or unstamped cache is rejected with a
logged reason and re-extracted, on both surfaces), firmware registration,
the [RAG](@ref gloss_rag) index, the hook generator, the recommender, comms
classification (the same classifier-and-merge the UI runs on every graph
load — in memory by default, written back with `--save-comms`) and
virtualization plus its UDP bus servers, and the object-group classifier —
then runs the loop with accept-all review and the report sink. Flags and the
container invocation are in @ref cli and @ref containers.

## Reading a session afterwards

Ask three questions, in order: What was the coverage trajectory across
rounds (`summary.md` — its table marks each round `BEST` / `REVERTED` and
also carries the round's synthesis time and first stop; below it come a
"session finished holding round N's overlays (best: X executed)" line,
cumulative selection / generation / advisor time, an artifact-census
section, and a Files index of every round's report files)? Which
recommendations were applied each round, and did the round
after them improve (`round_NN.md` — ordered as the round's story: what
changed going in and why, what happened (stop log + time split), results,
why it stopped where it did, hooks in effect with human-readable artifact
labels, frontier, and an artifact census)? Why did it stop —
`maxRounds` means the session used its round budget, `noCoverageProgress`
means it ran out of moves that changed anything — coverage stayed frozen,
every recommendation was refused as destructive, or rounds kept being
reverted. @ref autotune_decisions has
the longer version, including which file to open when a recommendation looks
wrong.

## In short

One plain-Dart engine: recommend → review → dedupe → refuse/warn → filter →
author → apply → re-synthesize → snapshot → measure (a round that collapses
coverage is reverted wholesale), with a no-progress detector, a stagnation
detector that escalates once before giving up, a best-so-far anchor whose
overlays every non-error exit restores, and named stop reasons. The CLI and
the UI differ only in which review policy and sink they inject — both write
the same report files, and both default to cold-start rounds. The decision
at the center of each round is @ref autotune_decisions.
