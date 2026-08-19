# Synthesis: A Single Run {#synthesis}

[Synthesis](@ref gloss_synthesis) is Resect's core move: run the firmware,
and every time it faults on hardware the emulator doesn't model, install a
[hook](@ref gloss_hook) at the faulting function and try again. This page
walks one run of the [synthesizer](@ref gloss_synthesizer)
(`SynthesizerWorkflow.run` in
`emulator_orchestrator/lib/orchestrator/workflows/synthesizer_workflow.dart`)
from setup to [manifest](@ref gloss_manifest).

Everything the run consumes — the [call graph](@ref gloss_call_graph), the
[bindings](@ref gloss_binding), the object groups, the comms assignments —
was produced before it started: that's @ref pre_synthesis.

## The idea in one paragraph

Firmware built for real hardware constantly touches memory-mapped
peripheral registers. Inside [Renode](@ref gloss_renode), a register nothing
models raises an [unhandled access](@ref gloss_unhandled_access), and Renode
pauses, naming the [symbol](@ref gloss_symbol) that touched it. That pause
*is* the signal: hook that symbol so the function no longer needs the
missing hardware, reset, and run again. Each iteration gets one function
further. The run "succeeds" when the firmware runs for the whole
observation window with no unhandled faults left.

## Before the first iteration: pre-seeding

The synthesizer starts by installing everything the
[project](@ref gloss_project) already knows, in the precedence order defined
in [Hook Overlays](@ref hook_overlays):

1. [overrides](@ref gloss_override) (with their [scopes](@ref gloss_scope)),
2. comms forwarding hooks from @ref comms_virtualization,
3. [warm-start](@ref gloss_warm_start) hooks from the last successful run,
4. any [object group](@ref gloss_object_group) the user or the LLM marked
   `forced` — installed whole, before any member faults (@ref symbol_groups).

Every pre-seeded hook is recorded in the manifest with its source, so you
can always answer "why is this hook here?"

## The loop

Each iteration, up to the iteration cap:

1. **Reset and reload.** A fresh machine every iteration — reset, reload the
   firmware, re-define every hook collected so far, and re-anchor them
   (`AddHookAtSymbol`, carrying each hook's scope).
2. **Run** and wait up to the **30-second observation window** for a pause.
   No pause within the window means the firmware ran clean: the run
   succeeds.
3. On an unhandled-access pause at symbol *S*, in this order:
   - **A forced override at *S* failed** → stop immediately with
     `forcedOverrideFailed`. An override is an instruction, not a
     suggestion; the synthesizer will not quietly try alternatives.
   - ***S* belongs to a recognized object group** (and the group isn't
     suppressed) → force-install the coherent hook for *every* member of
     that group under one shared scope, at most once per group per run, and
     re-run. A peripheral's enable/disable/is-ready functions only make
     sense hooked together.
   - **Otherwise rank candidates for *S*** — [preference](@ref gloss_preference)
     first, then effective score (the binding's fidelity where one exists,
     else the artifact's [intrinsic score](@ref gloss_intrinsic_score)).
   - **If nothing specialized is left to try** (no candidate scoring ≥ 0.5),
     engage the [LLM fallback](@ref gloss_llm_fallback): author a fresh hook
     for *S*, store it as an artifact, seed a binding at 0.5, and re-run
     with it sorted to the front. Generic templates remain as a last resort
     *after* the LLM attempt. @ref pre_synthesis explains why the threshold
     rather than literal exhaustion.
   - **Apply the best untried candidate** and record the attempt, tagged
     `binding`, `llm_on_demand`, or `iteration_fallback` depending on where
     it came from.
4. Repeat. A symbol whose candidates are genuinely exhausted fails the run.

## How a run ends

Every exit records a [termination reason](@ref gloss_termination_reason) on
the result and the manifest:

| Reason | Meaning | `failedSymbol` |
|---|---|---|
| `cleanRun` | The observation window elapsed with no pause. Success. | null |
| `symbolExhausted` | A symbol ran out of candidates (or had none). | the symbol |
| `forcedOverrideFailed` | An overridden hook faulted anyway. | the symbol |
| `maxIterations` | The iteration cap was reached. | **null** |
| `cancelled` | Stopped from outside. | null |

The `maxIterations` row is the interesting one. Hitting the cap is a
control-flow outcome, not a fault at a function, so `failedSymbol` stays
null. Reserving that field for *real* symbols is what keeps everything
downstream honest: @ref autotune_decisions routes its two jobs on it, and
before the distinction existed the cap wrote a sentinel string there and the
auto-tune loop dutifully authored a hook for a symbol named
`MAX_ITERATIONS_REACHED`.

The cap itself is a [stopping condition](@ref gloss_termination_reason), and
a generous one: 500 iterations by default headless. The 30-second window is
the real time bound on a run.

## What comes out

- A `SynthesizerResult` — the success flag, the iteration count, the
  resolved symbol → hook maps (which become the next run's warm start), the
  termination reason, and three execution signals:
  `failedSymbol` (a real fault, or null), `finalExecutionSymbol` (the last
  function the firmware *entered*, valid even on a clean run that never
  paused), and `recentExecutionTrace` (the last 16 function entries,
  oldest→newest).
- A [manifest](@ref gloss_manifest) — the durable per-symbol record of every
  decision and attempt, written to `manifests/<run_id>.json` in the project
  directory, then enriched with [fidelity](@ref gloss_fidelity) metrics and
  [executed symbols](@ref gloss_executed_symbols) collected from the trace
  stream.

Those three signals exist for the loop above this one: they are the evidence
@ref autotune_decisions hands the LLM to answer "where did it stop, and
why?"

The Synthesize tab shows the run live (console, trace rail, report); the CLI
`synthesize` command prints the result as JSON. Both drive this same
workflow — see @ref cli.

@note **Deviation from the current code.**
**Today:** folding fidelity metrics into a finished result is implemented
four times — in the UI's `SynthesisController`, the UI's auto-tune loop, the
CLI `synthesize` command, and the HTTP API — instead of all four calling the
shared helper (`enrichSynthesizerResult` in `auto_tune_engine.dart`, which
only the CLI's `autotune` command uses).
**Planned:** @ref phase_p1 routes all four through the shared helper.
**Why:** four copies of the same metric math can disagree, and a fix to one
silently misses the other three.

## Success is not the finish line

A "successful" synthesis means the firmware *ran the observation window
without faulting* — it says nothing about how much of the firmware ran, or
how faithfully. A run that hooks 40 functions into `return 0` can succeed
with terrible [coverage](@ref gloss_coverage). That's why results carry
fidelity metrics, and why the next pages exist: @ref autotune is the loop
that tries to make successive runs *better*, not just successful, and
@ref autotune_decisions is how it decides what to change.

## In short

Pre-seed what the project knows (overrides → comms → warm start → forced
groups), then iterate: reset, run for 30 seconds, and on a pause either fail
fast on a broken override, hook the faulting symbol's whole object group, or
apply the best-ranked candidate — engaging the LLM as soon as nothing
specialized is left. Out comes a result carrying a named termination reason
and where execution actually got to, a warm start for next time, and a
manifest that explains every decision.
