# Auto-tune Decision Making {#autotune_decisions}

@ref autotune describes the machinery of the closed loop — the engine, its
two seams, its [stopping conditions](@ref gloss_termination_reason). This
page is about the decision at the center of each
[round](@ref gloss_round): what evidence the LLM is given, in what order,
what it is allowed to say back, and what happens to the answer. If you are
debugging *why* a session chased the wrong symbol for four rounds, this is
the page.

The question every round asks is narrow, and worth stating exactly:

> Given where the firmware actually stopped, and what hooks are currently in
> effect, which overlay edits are most likely to make the next run reach
> more code?

Everything below is in service of making that question answerable from
evidence rather than from the model's priors about firmware.

## The evidence packet

`RecommendationService.composePrompt`
(`emulator_orchestrator/lib/services/llm/recommendation_service.dart`)
assembles the round's prompt; the context sections come from
`LastRunInsightService.composeContext`, shared with the Last Run advisor
card so both surfaces reason over identical facts. The sections appear in
this order, and the order is deliberate — runtime position first, catalog
and history last:

| # | Section | What it establishes |
|---|---|---|
| 1 | **Run outcome** | Where execution stopped, and how it got there |
| 2 | **Current run metrics** | Whether improvement is even possible |
| 3 | **Decisions applied during this run** | What the synthesizer did, latest first (comms pre-seeds collapsed to a count) |
| 4 | **Call-graph neighborhood** | The callers/callees around the stop point |
| 5 | **Current project overlay** | Which hook each nearby symbol resolves to, and whether it took effect |
| 6 | **Configuration drift** | Hooks added/removed since the run (when any) |
| 7 | **Coverage frontier** | Where forward progress stopped expanding (job 2 only) |
| 8 | **Available hook artifacts** | The real `artifact_id` values that exist |
| 9 | **Object groups** | Peripherals in play this round, as units |
| 10 | **Retrieved context** | [RAG](@ref gloss_rag): the stop symbol's decompilation + similar hooks |
| 11 | **Auto-tune round history** | The last 3 rounds' metrics, deltas, and what was tried |
| 12 | **Feedback from last round** | The escalation instruction, plus what was refused, reverted, or skipped |
| 13 | **Optimization target** | The user's bias, when set |
| 14 | **Your task** | Job framing + playbook + the JSON contract |

### Section 1: where execution stopped

This section is the newest and the most load-bearing. Up to seven lines,
each answering a different question:

    ## Run outcome
    - ELF: aya_ppg.elf
    - Iterations: 14
    - Duration: 42.202s
    - Synthesizer completed without throwing: true
    - Halt point: `Error_Handler` (last function entered before the run ended)
    - Recent call sequence (last 16 entered, oldest→newest): `PeriphCommonClock_Config` →
      `memset` → `HAL_RCCEx_PeriphCLKConfig` → `LL_RCC_SetSMPSPrescaler` → `MX_GPIO_Init` →
      `memset` → `LL_AHB1_GRP1_EnableClock` (×2) → `HAL_GPIO_Init` →
      `HAL_PWREx_EnableGPIOPullUp` → `RT_DEBUG_GPIO_Init` → `MX_I2C1_Init` → `HAL_I2C_Init` →
      `HAL_I2CEx_ConfigAnalogFilter` → `HAL_I2CEx_ConfigDigitalFilter` → `Error_Handler`
      ↳ `Error_Handler` looks like an error/fault handler. The real failure is the call JUST
        BEFORE it in the sequence — fix THAT …

(A verbatim excerpt from a real round's `round_NN_trace.txt`.)

**"Synthesizer completed without throwing"** is a deliberate relabeling.
The synthesizer's `success` flag only means "no unhandled access was left
at the end of the run" — a run that hooked forty functions to `return 0`
satisfies it. Labeled as plain `Success: true`, the model reliably
concluded nothing was wrong on runs with 2% coverage.

**The [halt point](@ref gloss_halt_point)** is resolved by one shared cascade,
`LastRunInsightService.computeHaltSymbol`, in strict priority order:

1. `failedSymbol` — a genuine unhooked fault (the run failed).
2. `finalExecutionSymbol` — where execution *actually got to*, captured
   from the last function entry Renode reported.
3. `lastPauseSymbol` — the last unhandled-access pause, which on a
   completed run is a fault the firmware was already hooked *past* and is
   therefore stale.
4. The chronologically-last synthesizer decision — a synthesizer action,
   not an execution location, and a last resort.

Order 2-before-3 is the whole point: centering the neighborhood and the
region on a hooked-past pause instead of the real end point is how earlier
sessions ended up reasoning about `HAL_I2C_Init` while the firmware was
sitting in `Error_Handler`.

**The [recent call sequence](@ref gloss_recent_call_sequence)** is the path *into* the stop point — the last
16 function entries, oldest to newest, consecutive repeats collapsed to
`` `sym` (×N) `` so a busy-wait spin is visible as a spin. It comes from a
ring buffer on the emulation controller, fed by Renode's function-entry
events and cleared at the top of every synthesizer iteration, so it
describes the final iteration only. Its value is causal: "where did it
stop" is a location, "how did it get there" is a diagnosis. When the last
entry looks like an [error sink](@ref gloss_error_sink) — `Error_Handler`, `*Fault*`, `assert`,
`abort`, `panic`, `_exit` — the section says so, and says the fix is the
call *before* it.

### Section 2: whether improvement is possible

    ## Current run metrics
    - Overall fidelity: 0.957 (averaged across the entire call graph)
    - Coverage fidelity: 0.412 (averaged over only executed symbols)
    - Symbols executed: 143 of 945 (15.1%)
    - Reachable-code coverage: 143 of 187 reachable (76.5%) — 44 reachable-but-unexecuted
      symbol(s) remain (the realistic room to improve; near 0 means coverage of the
      reachable code is essentially complete). Reachable set is from direct calls only
      (objdump), so it under-counts — treat the raw executed/total above as the baseline.
    - Symbols hooked: 61 (intact 884, degraded 61)

Two coverage numbers, on purpose. **Raw `executed / total`** counts
unreachable library and dead code in the denominator, so it reads
catastrophically low even on a healthy run — but it is stable across
versions and is the honest baseline for comparing runs.
**[Reachable-code coverage](@ref gloss_reachable_coverage)** computes the
universe reachable from what executed and reports the *headroom*: the count
of reachable-but-unexecuted symbols. Near zero
headroom means there is little left to win; large headroom means the
firmware is blocked, not finished. That distinction is what lets the model
say "no further action" credibly instead of inventing work. Because the
[call graph](@ref gloss_call_graph) has direct calls only
(@ref pre_synthesis), the reachable set under-counts, and the prompt says
so inline rather than letting the model over-trust it.

### Section 5: what each nearby hook actually does

Counts alone ("14 forced overrides, 61 bindings") hid the fact that
mattered: *which* artifact each symbol near the stop point resolves to, and
whether it took effect. So the overlay block renders per-symbol lines for
the region — the halt symbol's neighborhood plus the frontier — with the
hook's human-readable effect joined in from the catalog:

    - `HAL_I2CEx_ConfigAnalogFilter` ← #1 (forced override, "Return 0")  ← EXECUTION STOPPED
      HERE: if this hook is wrong (e.g. a ready/busy flag forced to the wrong value, or a
      Return-0 that masks forward progress), replace it.
    - `LL_RCC_LSI_IsReady` ← #4 (binding, classifier:rule-5-busy-ready-flag, "Return 1" —
      NOT applied this run — takes effect only on fault or if promoted to a forced override)

Three distinctions are encoded there, each fixing an observed failure mode:

- **`"Return 0"` / `"Return 1"` / `"Stateful increment"`** — the effect
  label, so the model can judge whether a hook is *wrong* without
  hand-joining artifact ids to the catalog. Without it, the model knew an
  override existed but not its value, and said so in its own reasoning.
- **ALREADY IN EFFECT vs NOT applied this run** — a
  [binding](@ref gloss_binding) applies only when its symbol *faults*, and
  a silent busy-wait never faults. So a bound-but-inert hook is a promotion
  opportunity, while re-forcing an in-effect one is a wasted round. The
  distinction is computed from the run's own manifest.
- **EXECUTION STOPPED HERE** — pinned first in the list so the line cap
  can't drop it, and carrying the one instruction that counters "already in
  effect = done": the hook at the stop point is the one most likely to be
  the wrong hook.

### Section 7: the frontier, annotated

The [frontier](@ref gloss_frontier) is the set of executed functions with
at least one never-executed callee — the boundary where progress stopped
expanding (`services/analysis/coverage_frontier.dart`, top 12 by unreached
callee count). Each callee is annotated from what the
[classifier](@ref gloss_classifier) already determined, via the binding's
`classifier:rule-N` [provenance](@ref gloss_provenance):

    - `LL_RCC_HSE_IsReady — ready/busy flag → #4; bound but NOT applied this run —
       promote to a forced override to take effect`
    - `LL_RCC_GetSystemClockFreq — clock getter → #6 (64 MHz); ALREADY IN EFFECT this run`
    - `LL_APB1_GRP1_EnableClock — void register writes — forcing a return value won't help`
    - `HAL_I2C_Master_Transmit — comms:i2c — virtualized, do not force individually`
    - `__aeabi_uidiv — (unresolved: not a call-graph function — cannot be hooked to advance
       coverage)`

This is the annotation layer paying off: the model is told what each
candidate *is*, from its decompiled body, instead of guessing from its
name. Where @ref pre_synthesis couldn't run (no Ghidra), these annotations
are simply absent and the model is back to name-guessing.

## Two jobs, routed by outcome

`RecommendationMode` splits the round into two framings, resolved from the
manifest when the caller passes `auto`:

- **Job 1 — reactive authorship** (`failedSymbol` is set). An unhandled
  access fired at a symbol whose catalog templates are exhausted. The task
  framing names that symbol and asks for the change most likely to get past
  it — usually `generate_custom_hook`, since templates already lost.
- **Job 2 — proactive coverage** (no failed symbol). The run completed or
  timed out but covered little: the firmware is stuck somewhere that never
  faults, so the reactive mechanism can't see it. This is where the
  playbook applies.

The routing hinges on `failedSymbol` meaning *only* "a real symbol faulted
and we ran out of hooks for it." That is why hitting the iteration cap
records a [termination reason](@ref gloss_termination_reason) and leaves
`failedSymbol` null — before that, the cap wrote a sentinel string into the
field, the router read it as job 1, and the loop authored a hook for a
symbol named `MAX_ITERATIONS_REACHED`.

## The job-2 playbook

Job 2's framing is an explicit, ordered playbook — it encodes the manual
session that took the reference firmware from 25 to 136 executed symbols:

0. **Stall point first.** The halt symbol is where progress stopped. If it
   is already hooked, the hook itself may be *wrong* — a flag forced to the
   wrong value, or a `Return 0` masking progress. Replacing it is the one
   case where re-touching an in-effect hook is not a wasted round. And if
   the stall symbol is an error/fault handler, do not hook it: read the
   recent call sequence and force the call *before* it to succeed.

Then an unnumbered **principle** every step is an instance of: a hook
*stands in* for the function it replaces — pick the behavior its callers
would observe from the original (flags read as states, counters and time
advance between calls, status returns use the callee's own convention) —
and every round is *measured*: a round that makes coverage collapse is
reverted wholesale and remembered.

1. **Spin rule.** If the recent call sequence shows the *same* function
   repeated (`(×N)`) and that function is not already hooked, the firmware
   is parked in a wait loop polling it. Force that function first — it
   beats every other move when it applies; the loop exits on the answer
   the hook gives, chosen per step 2.
2. **Value choice.** Decide what a function *returns* before picking its
   artifact. Ready/active checks → `Return 1`; busy → `Return 0`;
   `Get*`/`Read*` names return a *value*, never a success code —
   time/tick/count readers get the incrementing template so time advances,
   clock getters a realistic Hz value, and anything unclear a
   `generate_custom_hook` rather than a guessed constant. Frontier
   annotations come from decompiled bodies and outrank the name. Promote
   the ones marked NOT applied; skip the ones marked already in effect
   (except the step-0 stall point).
3. **[Wrapper-skip](@ref gloss_wrapper_skip) — an experiment, paid for by
   revert.** When steps 1-2 are exhausted and coverage still won't move,
   the spin may be *inlined* inside an executed frontier caller. Skipping
   that caller with `Return 0` deletes its whole body — everything beneath
   it, including working hooks, stops happening — so prefer the caller the
   halt evidence places the stall inside, and batch only skips that are
   individually defensible: the round is measured, and a coverage collapse
   reverts it wholesale.

Two cautions close the playbook, unnumbered because they are re-emitted on
escalation rounds too: **hands off** (comms-virtualized symbols are covered
as a bus, never individually; void register-writers gain nothing from a
forced return) and **boundary only** (target executed symbols or their
direct unreached callees — a forced override on code execution never
reaches does nothing).

Plus a batching instruction: emit up to `maxRecommendationsPerRound` (10)
edits, every one with its own defensible rationale and never more than one
recommendation for the same symbol — classify the whole frontier in a
round rather than one flag per round.

## Making bad answers unrepresentable

Prose guidance is advisory; the response schema is not. Every round builds
a fresh Ollama constrained-decoding schema
(`buildRecommendationSchema`) from live state:

- **Per-kind `anyOf` branches.** Each recommendation kind's payload fields
  are `required` at the decoder, so a `set_forced_override` without an
  `artifact_id` is unrepresentable. Before this, the flat schema required
  only kind + rationale, the model emitted id-less overrides, every entry
  failed to decode, and the round ended as a false "LLM returned nothing."
- **`artifact_id` enum = the real catalog ids.** Deleting a template leaves
  a permanent AUTOINCREMENT hole; without the enum the model picked ids
  from the contract example that pointed nowhere.
- **`symbol` enum = the round's candidates ∩ the call graph.** Candidates
  are the halt symbol, the frontier and its unreached callees (job 2), the
  halt symbol's callers and callees, and every symbol in the overlay or the
  manifest. Intersecting with the call graph is what makes a control-flow
  sentinel or a hallucinated name unrepresentable. `kProtectedSymbols` —
  the entry points `main`, `Reset_Handler`, `_start` — are subtracted from
  every variant of the enum (normal, escalation, and error-sink), so an
  entry-point override is unrepresentable at the decoder. Comms symbols are
  excluded (the halt symbol is always retained); if exclusion would empty
  the set, the pre-exclusion set is kept, because an empty enum
  unconstrains the field entirely.
- **Two narrowing branches** replace that candidate set when the round has
  a sharper answer:
  - *[Escalation round](@ref gloss_escalation_round)* — after a stagnant round, the enum is only the
    stalled frontier callers, making a repeat of the previous round's
    answer impossible. At temperature 0 the model had reproduced its prior
    recommendations token-for-token straight through an imperative
    do-not-repeat instruction; constrained decoding is the lever prose
    wasn't. The escalation framing *augments* the playbook rather than
    replacing it — the hands-off and boundary-only cautions are re-emitted,
    and the old batch-kill instruction is replaced with "start with one
    skip, batch more only when each is individually defensible" (the
    batch-kill version produced the observed self-destruction). Each
    stalled-caller candidate is annotated with its cost: whether it ran
    cleanly this round, and which working hooks live beneath it that a
    Return-0 skip would disable.
  - *Error-sink round* — when execution ended in a handler, the enum is
    the symbols on the recent call path into the sink, excluding the sink
    itself. The failing call is on that path by construction.
- **Group branches only when groups are relevant**, so the model can't
  invent an object scope that doesn't exist.

Enum membership is enforced by the decoder, but Ollama's enforcement has
proven **soft** in practice — an off-path symbol was observed leaking past
a restricted enum. So two more layers stand behind it:

1. **Parse-time validation.** `_parseOutput` drops any
   symbol-targeting recommendation whose target isn't a call-graph symbol,
   and also drops any override, preference, or generate targeting a
   protected entry point (`clear_forced_override` is exempt — removing an
   override is always safe), logging each drop. A batch where the model
   emitted entries but *none* survived decoding is reported as a parse
   failure, not as an empty answer — reporting it as empty used to end
   live sessions while the model was actively (if invalidly) recommending.
2. **Engine-side validation.** `AutoTuneEngine` re-checks
   `generate_custom_hook` targets against the call graph before authoring,
   so a leaked name can't seed a bogus artifact and binding. It also hard-
   refuses any forced override that still names a protected entry point,
   attaches advisory warnings to risky-looking moves (a constant on a
   time/counter reader, a Return-0 skip of a cleanly-executed caller with
   working hooks beneath it), and measures every round against the
   session's best — a round whose executed count collapses below half the
   best is reverted wholesale (see @ref autotune).

## Sampling: a decision, not a derivation

The recommendation call runs the `job2Coverage` profile
(`services/llm/llm_profiles.dart`): **thinking off, temperature 0**,
topP 0.95 / topK 64, 16k context, 1600 response tokens, on the configured
model. Picking from a catalog is a decision; before this was a profile, the
call ran think-on at temperature 1.0 with an 8192-token budget and the
model spent the entire budget on a 7600-chunk thinking spiral, emitting
zero response tokens. The 1600-token budget is sized for a full 10-entry
batch with rationales — on a CPU-bound host the budget *is* the worst-case
round time.

## From reply to next run

    recommend → review → dedupe → refuse/warn → filter no-ops → author → apply
        → re-synthesize → report + snapshot → measure/revert → check

      review         accept-all (CLI) or human Accept/Reject/Edit (UI)
      dedupe         identical entries within one reply collapsed
      refuse/warn    entry-point overrides refused; risky moves warned
      filter no-ops  already-in-effect edits dropped
      author         generate_custom_hook bodies written + bound
      apply          overlays mutate in place (pre-round state kept)
      measure/revert executed count below half the session best →
                     the whole round's changes rolled back

The **no-op filter** (`filterNoOpRecommendations` in
`orchestrator/auto_tune_progress.dart`) is what stops the loop burning a
full synthesis round on an identical run. Per kind: a forced override is a
no-op when the same artifact is already forced with the same scope, *or*
when the last run's manifest shows that artifact was applied reactively
anyway — identical body, identical firmware behavior, only the timing
differs. A scope change is *not* a no-op. Preferences are no-ops when
already selected; a clear is a no-op when there's nothing to clear;
authoring and cap changes are never filtered. Skipped entries are reported
in the round file *and* fed into the next round's feedback as
"do not repeat these" — alongside anything the engine refused (entry-point
overrides) and, after a reverted round, the reverted moves with their
measured outcome ("executed fell 39 → 15").

If every accepted recommendation is filtered, the engine doesn't
re-synthesize at all — it counts the round as stagnant and escalates,
because re-running unchanged overlays produces identical evidence.

## When the loop stops

Two detectors, both pure functions, both shared so the UI and CLI can't
drift:

- **`isNoProgress`** — the round failed at the same symbol as the round
  before AND the tried-artifact set gained nothing. A different symbol, a
  new hook at the same symbol, or either round not failing all count as
  progress. Ambiguity errs toward continuing: a repeat only stops the
  session when it can be positively confirmed.
- **`isCoverageStagnant`** — a successful round reached no symbol the
  previous round hadn't. A *shrunken* set is also stagnant: a wrapper-skip
  that cost one symbol and gained none is not progress, and treating it as
  movement reset the escalation counter. The first stagnant round triggers
  the escalation feedback; `stagnantRoundLimit` (default 2) consecutive
  stagnant rounds end the session with `noCoverageProgress`.

Every ending is a named `AutoTuneStopReason`. Read them as three families:

| Family | Reasons | Meaning |
|---|---|---|
| Converged | `llmEmpty`, `noCoverageProgress`, `noProgressOnSymbol` | The loop ran out of defensible moves |
| Budget | `maxRounds` | The round budget ran out — not the same as done |
| Human | `userStopped`, `userRejectedAll`, `cancelled` | A reviewer ended it |
| Failure | `baselineFailed`, `parseFailed`, `synthesisError`, `llmError` | Something broke; the round files say what |

## Reading a session afterwards

Every session — UI or headless, the report sink runs on both surfaces —
writes everything it did to `autotune_reports/<timestamp>/` (see
@ref storage_map). Read it in this order:

1. **`summary.md`** — the per-round trajectory. Coverage and fidelity per
   round, and the stop reason. The shape of the trajectory tells you which
   round to open next.
2. **`round_NN.md`** for the round where the trajectory turned — outcome,
   metrics, the frontier at that point, the synthesizer's decisions, and
   the LLM's recommendations *with their rationales* plus what was applied
   and what was filtered as a no-op.
3. **`round_NN_trace.txt`** when the recommendation looks wrong. This is
   the exact prompt sent, the thinking (if any), and the raw response. If
   the model chose badly, this file shows whether it chose badly *from good
   evidence* — which is a prompt bug — or from bad evidence, which is a
   signals bug.
4. **`round_NN_manifest.json`** for per-symbol ground truth: every decision,
   every attempt, the [termination reason](@ref gloss_termination_reason),
   the final execution symbol, and the recent call sequence.

This used to be a deviation — the loop kept no best-so-far anchor, so a
session that peaked mid-run ended holding the *last* result, not the best
one (observed live: coverage peaked at 143 executed symbols in round 5 and
the session finished at 107). Resolved: the engine now tracks the best
round's executed count and overlays, reverts any round that collapses below
half of it, and restores the best round's overlays on every non-error exit
(see @ref autotune).

@note **Deviation from the current code.**
**Today:** the wrapper-skip in playbook step 3 is always a blunt
`Return 0` on the caller: its body, and every side effect in it,
disappears — though a bad skip is now *measured*: a round whose coverage
collapses is rolled back wholesale by the revert mechanism, so the cost is
one round, not the session. The
[classifier](@ref gloss_classifier)'s template-vs-author decision (which
*does* read the decompiled body) never runs on the auto-tune path, and
`AutoTuneEngine._generateAndSeedCustomHooks` calls the hook generator
without a signature, so the generator's classifier short-circuit and its
signature/struct prompt blocks stay inert.
**Planned:** feed the decompilation into both the template-vs-author
decision and the authoring prompt on the auto-tune path, and record the
decision on the manifest (unscheduled; captured in `TODO.txt`).
**Why:** "skip the whole function" is the only wrapper move available
today, so a wrapper that does anything necessary can only be skipped or
left alone.

## In short

Each round hands the model a fixed-order evidence packet that leads with
runtime position — where execution stopped, the 16-entry path into it, and
whether an error sink swallowed it — then improvability (raw coverage plus
reachable-set headroom), then what each nearby hook actually does and
whether it took effect, then the annotated frontier, the catalog, and the
round history. Job 1 fires on a real fault and asks for authorship; job 2
fires on low coverage and follows the playbook — stall point first, spin
rule, value choice, wrapper-skip as a measured experiment, two standing
cautions. What the model may
answer is constrained by a per-round schema built from live catalog ids and
call-graph symbols, narrowed further on escalation and error-sink rounds,
and backstopped by parse-time and engine-side validation because the
decoder's enforcement is soft. Accepted edits are deduped, filtered for
no-ops, applied to the overlays, and re-synthesized; every round is
measured against the session's best (a collapse is reverted wholesale),
and two pure detectors decide when the session has stopped earning its
rounds.
