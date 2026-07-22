# Glossary {#glossary}

Every term of art used in these docs, defined once. Pages link here the
first time they use a term; if you add a new term to a page, add it here
too and link it. Entries are alphabetical.

## Artifact {#gloss_artifact}

A stored piece of reusable content in the
[artifact database](@ref gloss_artifact_db). In practice today every
artifact is a [hook](@ref gloss_hook) body — a row holding Python source
plus metadata (name, origin, target symbol, [intrinsic score](@ref gloss_intrinsic_score)). See @ref model_artifacts.

## Artifact database {#gloss_artifact_db}

The global SQLite database (managed with the Drift package) at
`~/.config/call_graph_viewer/artifact_library/artifacts.db`. It stores hook
bodies, registered firmware, and cached [Ghidra extraction](@ref gloss_ghidra_extraction) facts, all keyed by [ELF hash](@ref gloss_elf_hash). It is data model #1 of the architecture. See
@ref model_artifacts.

## Auto-tune {#gloss_autotune}

The closed loop that runs [synthesis](@ref gloss_synthesis) repeatedly,
asking an LLM for [recommendations](@ref gloss_recommendation) between
[rounds](@ref gloss_round) and applying the accepted ones, until fidelity
stops improving or a limit is hit. See @ref autotune.

## Binding (HookBinding) {#gloss_binding}

A per-project, per-symbol record declaring that a particular
[artifact](@ref gloss_artifact) is a suitable hook for a particular
[symbol](@ref gloss_symbol), with a [fidelity](@ref gloss_fidelity)
estimate and a [provenance](@ref gloss_provenance) saying who decided
that. Bindings are suggestions the
synthesizer ranks — unlike an [override](@ref gloss_override), they don't
force anything. See @ref hook_overlays.

## Call graph {#gloss_call_graph}

The directed graph of which functions call which, extracted from the
firmware binary — via objdump by default, or from the cached
[Ghidra extraction](@ref gloss_ghidra_extraction) when that module is
enabled (UI only today; the CLI always uses objdump). The foundation for
coverage math, the Call Graph tab, and hook targeting.

## Classifier {#gloss_classifier}

A deterministic rule engine (`HookClassifier`) that looks at a function's
signature, decompilation, and data symbols and picks a suitable catalog
hook template for it — no LLM involved. There is also a separate
name-pattern *comms* classifier that assigns symbols to a
[comms class](@ref gloss_comms_class). See @ref hook_lifecycle.

## Comms class {#gloss_comms_class}

Which bus family a symbol belongs to for
[comms virtualization](@ref gloss_comms_virtualization): `i2c`, `spi`,
`uart`, or `unclassified`. Stored per symbol on the
[project](@ref gloss_project) as a comms assignment (class + read/write
role).

## Comms virtualization {#gloss_comms_virtualization}

Redirecting the firmware's bus traffic (I2C/SPI/UART) out of the emulator:
a forwarding [hook](@ref gloss_hook) intercepts the read/write function and
sends the request over UDP to a [device handler](@ref gloss_device_handler)
running on the host, which answers in place of the missing peripheral. See
@ref comms_virtualization.

## Controller {#gloss_controller}

In Resect's MVC framing: the single class through which a data
[model](@ref gloss_model) is read and changed. Resect has two —
@ref controller_artifacts for the artifact database and
@ref controller_projects for projects. Both are plain Dart, so the UI and
the [CLI](@ref cli) drive the same one.

## Coverage {#gloss_coverage}

How much of the firmware actually ran: the set of [executed symbols](@ref gloss_executed_symbols) measured against the [call graph](@ref gloss_call_graph). Summarized by coverage
[fidelity](@ref gloss_fidelity).

## Device handler {#gloss_device_handler}

The host-side object that answers virtualized bus requests — the stand-in
for the missing physical peripheral. Built-ins: `ZeroDeviceHandler` (answers
reads with zeros) and `RandomDeviceHandler`. See @ref comms_virtualization.

## Docs-first {#gloss_docs_first}

Resect's rule that architecture changes are written into these docs before
they are made in code; the docs are the source of truth and the code aligns
to them. See @ref docs_first_policy.

## Engine {#gloss_engine}

The four capability interfaces (`EngineLifecycle`, `EmulationController`,
`CallGraphSource`, `TraceSource`) that the rest of Resect programs
against, plus whatever implements them. Today the one implementation is
`DartEngine`, which drives [Renode](@ref gloss_renode). Only engine
implementations talk to Renode. See @ref orchestrator_engine. (Despite
its name, `AutoTuneEngine` is not one of these — it drives the
[auto-tune](@ref gloss_autotune) loop.)

## ELF hash {#gloss_elf_hash}

The SHA-256 of a firmware ELF file. The [artifact database](@ref gloss_artifact_db) keys everything firmware-related by it, so
facts survive file moves and renames.

## Emulator (model class) {#gloss_emulator_model}

The Dart class `Emulator`
(`emulator_orchestrator/lib/data/models/emulator.dart`) that *is* a
[project](@ref gloss_project) in memory. The name is historical — read it as
"project." See @ref model_projects.

## Executed symbols {#gloss_executed_symbols}

The set of firmware functions observed actually running during an emulation,
collected from the Renode trace stream. The raw material of
[coverage](@ref gloss_coverage).

## Fidelity {#gloss_fidelity}

Resect's 0.0–1.0 score for "how faithful is this emulation to the real
firmware?" Three variants: **overall** (whole call graph, hooked functions
count as degraded), **coverage** (weights what actually executed), and
**subgraph** (restricted to the region between a start and end symbol).
Computed by `FidelityCalculator`. A [binding](@ref gloss_binding) also
carries a per-hook fidelity estimate — same scale, applied to one function.

## Frontier {#gloss_frontier}

The coverage frontier: functions that executed but whose callees did not.
Where forward progress stalled — [auto-tune](@ref gloss_autotune) uses it to
pick escalation targets. Computed by `computeFrontier`.

## Ghidra extraction {#gloss_ghidra_extraction}

An optional, cached analysis pass that runs Ghidra headlessly over the
firmware and stores function signatures, decompiled C, data types, data
symbols, and the memory map in the [artifact database](@ref gloss_artifact_db). Gated by the `MODULE_GHIDRA` flag in
`resect.config`. Powers the [classifier](@ref gloss_classifier),
[RAG](@ref gloss_rag) retrieval, and LLM prompts.

## Hook {#gloss_hook}

A small Python function installed into [Renode](@ref gloss_renode) at a
firmware [symbol](@ref gloss_symbol). When execution reaches that symbol,
the hook runs *instead of* the original function body — returning a stub
value, emulating the function's effect, or forwarding a bus request. Hook
bodies are stored as [artifacts](@ref gloss_artifact). See
@ref hook_lifecycle.

## Intrinsic score {#gloss_intrinsic_score}

A 0.0–1.0 suitability floor stored on an [artifact](@ref gloss_artifact)
itself, independent of any project. When a symbol has no
[binding](@ref gloss_binding), candidate hooks are ranked by intrinsic
score instead.

## LLM fallback {#gloss_llm_fallback}

The [synthesizer's](@ref gloss_synthesizer) last resort: when a paused
symbol has no suitable stored candidate left, ask the LLM (via
`LlmHookGenerator`) to author a fresh hook for it mid-run. See
@ref synthesis.

## Manifest {#gloss_manifest}

The `SynthesisManifest`: the durable record of one synthesizer run — every
per-symbol decision and attempt, the metrics, the executed symbols, and
timing. Written to `manifests/<run_id>.json` in the project directory. See
@ref storage_map.

## Model {#gloss_model}

In Resect's MVC framing: a data store plus the types that describe it, with
no behavior beyond (de)serialization. Resect has exactly two — the
[artifact database](@ref gloss_artifact_db) and the
[project](@ref gloss_project). See @ref architecture.

## Orchestrator {#gloss_orchestrator}

`EmulationOrchestrator`: the façade that composes an
[engine](@ref gloss_engine) with the emulation, analysis, and synthesis
workflows, and emits events. It owns no persistent data. The third
long-lived object of the architecture, alongside the two
[controllers](@ref gloss_controller). See @ref orchestrator_engine.

## Overlay {#gloss_overlay}

Collective name for the per-project, per-symbol hook-selection maps stored
on the [project](@ref gloss_project): [overrides](@ref gloss_override),
[preferences](@ref gloss_preference), override scopes, and
[bindings](@ref gloss_binding). See @ref hook_overlays.

## Override {#gloss_override}

The strongest [overlay](@ref gloss_overlay): "this symbol *must* use this
artifact." Applied before synthesis starts; if an overridden hook still
fails, the run fails rather than trying alternatives. See @ref hook_overlays.

## Preference {#gloss_preference}

A soft [overlay](@ref gloss_overlay): "when choosing candidates for this
symbol, try this artifact first." Unlike an [override](@ref gloss_override),
the synthesizer may move on to other candidates if it doesn't work. See
@ref hook_overlays.

## Project {#gloss_project}

Data model #2: one firmware re-hosting effort — the firmware paths, the
[overlays](@ref gloss_overlay), comms assignments, results, and history —
saved as a single `.emu` JSON file. In code the class is
[Emulator](@ref gloss_emulator_model). See @ref model_projects.

## Provenance {#gloss_provenance}

The string on a [binding](@ref gloss_binding) recording who created it:
`classifier:rule<N>`, `llm:...`, `harness+judge`, or `user`. Lets you judge
how much to trust the binding's fidelity estimate.

## RAG {#gloss_rag}

Retrieval-augmented generation: before asking the LLM to write a hook,
Resect retrieves the most relevant chunks of project documents and
[Ghidra extraction](@ref gloss_ghidra_extraction) facts from a per-project
index (`rag_index.db`) and puts them in the prompt.

## Recommendation {#gloss_recommendation}

One typed, machine-applicable change proposed by the LLM during
[auto-tune](@ref gloss_autotune): set/clear an
[override](@ref gloss_override), set a [preference](@ref gloss_preference),
generate a custom hook, or adjust the iteration cap. See @ref autotune.

## Renode {#gloss_renode}

The open-source systems emulator (from Antmicro) that actually runs the
firmware. Resect drives a patched portable Renode build in server mode and
installs [hooks](@ref gloss_hook) with its `AddHookAtSymbol` command.

## Review policy {#gloss_review_policy}

The [auto-tune](@ref gloss_autotune) engine's pluggable answer to the
question of who approves the LLM's
[recommendations](@ref gloss_recommendation). The CLI uses accept-all; the
UI presents them for human review. See @ref autotune.

## Round {#gloss_round}

One iteration of the [auto-tune](@ref gloss_autotune) loop: recommend →
review → apply → re-run [synthesis](@ref gloss_synthesis) → snapshot.

## Round snapshot {#gloss_round_snapshot}

The durable per-[round](@ref gloss_round) record stored on the
[project](@ref gloss_project): the [overlays](@ref gloss_overlay) at round
start, metrics, executed symbols, the recommendations and what the reviewer
decided, and a pointer to the round's [manifest](@ref gloss_manifest).

## Scope {#gloss_scope}

A Renode-specific string attached to a hook telling `AddHookAtSymbol` where
to anchor it (needed when a bare symbol name is ambiguous). Stored alongside
[overrides](@ref gloss_override) and on [bindings](@ref gloss_binding).

## Sink {#gloss_sink}

The [auto-tune](@ref gloss_autotune) engine's pluggable answer to "where do
progress and results go?" The CLI's sink writes per-round report files; the
UI's sink feeds the auto-tune modal. See @ref autotune.

## Stagnation {#gloss_stagnation}

When successive [auto-tune](@ref gloss_autotune) rounds reproduce the exact
same [executed-symbol](@ref gloss_executed_symbols) set (or every
recommendation is a no-op). After `stagnantRoundLimit` consecutive stagnant
rounds the engine escalates, then stops with the `noCoverageProgress`
reason. See @ref autotune.

## Symbol {#gloss_symbol}

A named function in the firmware binary, e.g. `HAL_I2C_Mem_Read`. The unit
that hooks attach to and that the [call graph](@ref gloss_call_graph) is
built from.

## Synthesis {#gloss_synthesis}

A single run of the [synthesizer](@ref gloss_synthesizer): repeatedly
execute the firmware, and each time it faults, install a hook at the
faulting symbol and try again — until the firmware runs cleanly or a limit
is hit. See @ref synthesis.

## Synthesizer {#gloss_synthesizer}

`SynthesizerWorkflow`, the component that performs
[synthesis](@ref gloss_synthesis). "Synthesizer run" and "synthesis run" are
used interchangeably.

## Unhandled access {#gloss_unhandled_access}

The fault that drives [synthesis](@ref gloss_synthesis): the firmware read
or wrote a memory address that nothing in the emulated platform models
(usually a missing peripheral register). Renode pauses, and the pause names
the [symbol](@ref gloss_symbol) that caused it.

## Warm start {#gloss_warm_start}

Re-using the resolved hook code from a previous successful run: the
project's `hooks` map is pre-seeded into the next synthesis so it doesn't
rediscover the same solutions. Weaker than [overrides](@ref gloss_override)
and comms hooks, which take precedence. See @ref hook_overlays.
