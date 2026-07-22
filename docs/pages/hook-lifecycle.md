# The Life of a Hook {#hook_lifecycle}

This page follows one [hook](@ref gloss_hook) from the moment it's written
to the moment it runs inside [Renode](@ref gloss_renode), naming the
component responsible at every step.

## What a hook actually is

A hook is a short Python function installed at a firmware
[symbol](@ref gloss_symbol). When the emulated CPU reaches that symbol, the
hook runs *instead of* the original function body — typically forcing a
return value, simulating the function's side effects, or forwarding a bus
request to the host. Hooks exist because the emulator doesn't model every
peripheral the firmware expects; a well-chosen hook papers over exactly one
missing piece of hardware.

Renode embeds IronPython 2.7, so hook bodies must be written in
**Python 2** syntax — hook code written with Python 3 idioms fails inside
Renode.

## Step 1 — Birth: three ways a hook comes to exist

1. **From the catalog.** `HookCatalog`
   (`emulator_orchestrator/lib/data/services/hook_catalog.dart`) builds
   parameterized templates: `return`, `read`, `write`, `increment`, and the
   comms forwarders `i2c_read`, `i2c_write`, `uart_read`, `uart_write`.
   The default set is seeded into the database on first run.
2. **From the [classifier](@ref gloss_classifier).** A deterministic rule
   engine inspects a function's cached signature, decompilation, and data
   symbols (from [Ghidra extraction](@ref gloss_ghidra_extraction)) and
   picks the catalog template that fits — for example, "returns a status
   int and touches no globals → `return 0`."
3. **From the LLM.** `LlmHookGenerator` composes a
   [RAG](@ref gloss_rag)-augmented prompt (the function's decompiled C, its
   signature, relevant document chunks) and streams a purpose-written body
   — used by the generation dialog, the synthesizer's
   [LLM fallback](@ref gloss_llm_fallback), and
   [auto-tune's](@ref gloss_autotune) custom-hook recommendations.

## Step 2 — Storage: one row in the artifact database

Whatever its birth, the body is stored once as an
[artifact](@ref gloss_artifact) row in the
[artifact database](@ref gloss_artifact_db) — deduplicated, imports
inlined, tagged with origin and (for purpose-written hooks) the target
symbol. Details: @ref model_artifacts.

@note **Deviation from the current code.**
**Today:** three components each contain their own copy of the
store-and-bind step: `SynthesizerWorkflow._tryLlmFallback` and the two
`_generateAndSeedCustomHooks` methods (one in `AutoTuneEngine`, one in the
UI's `LlmSynthesisOrchestrator`).
**Planned:** @ref phase_p3 folds all three into
`ArtifactController.generateAndBind`.
**Why:** the three copies must be kept identical by hand; the controller
makes the step exist once.

## Step 3 — Association: an overlay entry in the project

A stored body does nothing until a [project](@ref gloss_project) points a
symbol at it — a [binding](@ref gloss_binding) ("suits this symbol, this
well"), a [preference](@ref gloss_preference) ("try it first"), or an
[override](@ref gloss_override) ("must use it"). Those maps, and which one
wins, are the subject of @ref hook_overlays. Per the
[bodies-vs-associations rule](@ref bodies_vs_associations), this step
writes the `.emu` file, never the database.

## Step 4 — Selection: the synthesizer picks it

During a run, the [synthesizer](@ref gloss_synthesizer) chooses which
stored body each paused symbol actually gets, honoring the overlays
(@ref synthesis tells that story iteration by iteration).

## Step 5 — Deployment: into Renode

The chosen body is defined in the Renode monitor as a variable and anchored
to its symbol:

    set bmp180_read_temp_hook """<the Python body>"""
    sysbus AddHookAtSymbol "bmp180_read_temp" $bmp180_read_temp_hook

(issued by `DartEmulationController`, the engine implementation in
`emulator_orchestrator/lib/orchestrator/engine/dart/dart_emulation_controller.dart`;
a [scope](@ref gloss_scope) string, when present, disambiguates where the
symbol is anchored — note that scoped `AddHookAtSymbol` requires the
patched Renode portable build this repo pins). From then on, every time
execution reaches `bmp180_read_temp`, IronPython runs the hook instead of
the firmware's code.

## A complete example, end to end

`bmp180_read_temp` reads a temperature register that no emulated
peripheral backs, so the firmware faults there.

1. The LLM fallback authors a body that writes a plausible constant into
   the output buffer and returns 0 (**birth**).
2. The body is stored as artifact #42, origin `user`, target symbol
   `bmp180_read_temp` (**storage**).
3. A binding `{artifactId: 42, fidelity: 0.5, provenance: "llm:synthesizer"}`
   is saved into the project (**association**).
4. On the next run the synthesizer ranks #42 top for that symbol
   (**selection**).
5. `AddHookAtSymbol` installs it; the firmware gets past the sensor read
   (**deployment**).

The other Part III pages each zoom in on one of these steps.

## In short

Born from the catalog, the classifier, or the LLM; stored once, globally,
as an artifact row; associated per-project through the overlays; selected
by the synthesizer; deployed into Renode with `AddHookAtSymbol`. Five
steps, five owners, no shortcuts.
