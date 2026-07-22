# Synthesis: A Single Run {#synthesis}

[Synthesis](@ref gloss_synthesis) is Resect's core move: run the firmware,
and every time it faults on hardware the emulator doesn't model, install a
[hook](@ref gloss_hook) at the faulting function and try again. This page
walks one run of the [synthesizer](@ref gloss_synthesizer)
(`SynthesizerWorkflow.run` in
`emulator_orchestrator/lib/orchestrator/workflows/synthesizer_workflow.dart`)
from setup to [manifest](@ref gloss_manifest).

## The idea in one paragraph

Firmware built for real hardware constantly touches
memory-mapped peripheral registers. Inside
[Renode](@ref gloss_renode), a register nothing models raises an
[unhandled access](@ref gloss_unhandled_access), and Renode pauses,
naming the [symbol](@ref gloss_symbol) that touched it. That pause *is*
the signal: hook that symbol so the function no longer needs the missing
hardware, reset, and run again. Each iteration gets one function further.
The run "succeeds" when the firmware reaches the configured end point (or
runs cleanly) with no unhandled faults left.

## Before the first iteration: pre-seeding

The synthesizer starts by installing everything the
[project](@ref gloss_project) already knows, in the precedence order
defined in [Hook Overlays](@ref hook_overlays):

1. [overrides](@ref gloss_override) (with their
   [scopes](@ref gloss_scope)),
2. comms forwarding hooks from @ref comms_virtualization,
3. [warm-start](@ref gloss_warm_start) hooks from the last successful run.

Every pre-seeded hook is recorded in the manifest with its source, so you
can always answer "why is this hook here?"

## The loop

Each iteration, up to the iteration cap:

1. **Reset and reload** the firmware, re-define every hook collected so
   far, and re-anchor them (`AddHookAtSymbol`).
2. **Run** until success, the end symbol, or a pause.
3. On an unhandled-access pause at symbol *S*:
   - Gather candidate artifacts for *S* and rank them — the
     [preference](@ref gloss_preference) first, then best
     `binding.fidelity`, falling back to
     [intrinsic score](@ref gloss_intrinsic_score).
   - **Apply the best untried candidate** and record the attempt.
   - If no candidate scores at least 0.5, invoke the
     [LLM fallback](@ref gloss_llm_fallback): author a fresh hook for *S*,
     store it via the artifact path, seed a [binding](@ref gloss_binding),
     and apply it.
4. Repeat. A symbol whose candidates are all exhausted fails the run; a
   clean run succeeds.

One rule from @ref hook_overlays bears repeating: an
[override](@ref gloss_override) is an instruction, not a suggestion. If an
overridden hook faults, the run fails immediately instead of trying
alternatives.

## What comes out

- A `SynthesizerResult` — success flag, iteration count, the resolved
  symbol → hook maps (which become the next run's warm start), and the
  failure point if any.
- A [manifest](@ref gloss_manifest) — the durable per-symbol record of
  every decision and attempt, written to `manifests/<run_id>.json` in the
  project directory, then enriched with [fidelity](@ref gloss_fidelity)
  metrics and [executed symbols](@ref gloss_executed_symbols) collected
  from the trace stream.

The Synthesize tab shows the run live (console, trace rail, report); the
CLI `synthesize` command prints the result as JSON. Both drive this same
workflow — see @ref cli.

@note **Deviation from the current code.**
**Today:** folding fidelity metrics into a finished result is implemented
four times — in the UI's `SynthesisController`, the UI's auto-tune loop,
the CLI `synthesize` command, and the HTTP API — instead of all four
calling the shared helper (`enrichSynthesizerResult` in
`auto_tune_engine.dart`).
**Planned:** @ref phase_p1 routes all four through the shared helper.
**Why:** four copies of the same metric math can disagree, and a fix to
one silently misses the other three.

## Success is not the finish line

A "successful" synthesis means the firmware *ran to the end without
faulting* — it says nothing about how much of the firmware ran, or how
faithfully. A run that hooks 40 functions into `return 0` can succeed with
terrible [coverage](@ref gloss_coverage). That's why results carry fidelity
metrics, and why the next page exists: @ref autotune is the loop that tries
to make successive runs *better*, not just successful.

## In short

Pre-seed what the project knows (overrides → comms → warm start), then
iterate: run, pause at the faulting symbol, apply the best-ranked candidate
hook (LLM as last resort), reset, repeat. Out comes a result, a warm start
for next time, and a manifest that explains every decision.
