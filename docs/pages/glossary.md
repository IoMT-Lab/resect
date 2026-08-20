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
[rounds](@ref gloss_round) and applying the accepted ones, until coverage
(the [executed-symbol](@ref gloss_executed_symbols) set) stops improving
or a limit is hit. See @ref autotune.

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
coverage math, the Call Graph tab, and hook targeting. Every graph carries
an identity stamp — the SHA-256 of its source ELF (`elfHash`) — and
consumers validate that stamp against the firmware actually in use (via
`call_graph_guard.dart`) instead of trusting the path. Note that the objdump
graph carries **direct calls only** — calls through function pointers,
vtables, or interrupt vectors are absent, so it under-approximates
reachability. See @ref pre_synthesis.

## Classifier {#gloss_classifier}

A deterministic rule engine (`HookClassifier`) that looks at a function's
signature, decompilation, and data symbols and picks a suitable catalog
hook template for it — no LLM involved; "no template fits" is its other
answer, and the only trigger for LLM authoring. Two more components share
the name: the *comms* classifier, which assigns symbols to a
[comms class](@ref gloss_comms_class), and the *object-group* classifier
(@ref symbol_groups). All three, and the seven rules, are in
@ref pre_synthesis. See also @ref hook_lifecycle.

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
[fidelity](@ref gloss_fidelity). Reported two ways — raw `executed / total`,
and [reachable-code coverage](@ref gloss_reachable_coverage).

## Device handler {#gloss_device_handler}

The host-side object that answers virtualized bus requests — the stand-in
for the missing physical peripheral. Built-ins: `ZeroDeviceHandler` (answers
reads with zeros) and `RandomDeviceHandler`. See @ref comms_virtualization.

## Docs-first {#gloss_docs_first}

Resect's rule that architecture changes are written into these docs before
they are made in code; the docs are the source of truth and the code aligns
to them. See @ref docs_first_policy.

## Error sink {#gloss_error_sink}

A function where landing means an upstream check already failed —
`Error_Handler`, a `*Fault*` handler, `assert`, `abort`, `panic`, `_exit`.
Recognized by name (`LastRunInsightService.looksLikeErrorSink`). Hooking a
sink hides the failure without advancing coverage, so both the prompt framing
and the response schema push the LLM at the call *before* it in the
[recent call sequence](@ref gloss_recent_call_sequence). See
@ref autotune_decisions.

## Escalation round {#gloss_escalation_round}

The [auto-tune](@ref gloss_autotune) round that follows a
[stagnant](@ref gloss_stagnation) one: the prompt states that every leaf-level
fix is already in effect and the response schema is narrowed to the stalled
[frontier](@ref gloss_frontier) callers, so the model must propose a
[wrapper skip](@ref gloss_wrapper_skip) instead of repeating itself. See
@ref autotune_decisions.

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

## Group scope {#gloss_group_scope}

The shared [scope](@ref gloss_scope) string given to every member of an
[object group](@ref gloss_object_group) — the group key, e.g. `LL_RCC_LSI`.
Because the members share one scope, their scoped read/write hooks read and
write the same Renode Python-globals namespace, so enabling the object sets
state that its is-ready member reads back. See @ref symbol_groups.

## Halt point {#gloss_halt_point}

The one symbol a round's reasoning is centered on: where the firmware
stopped. Resolved by a fixed cascade —
`failedSymbol` (a real fault) → `finalExecutionSymbol` (the last function
*entered*) → `lastPauseSymbol` (a fault already hooked past, hence stale) →
the chronologically-last synthesizer decision. Shared by the recommender and
the Last Run advisor so both center on the same symbol. See
@ref autotune_decisions.

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

## Member role {#gloss_member_role}

What one function does within its [object group](@ref gloss_object_group),
inferred from its trailing action token: enable, disable, is-ready, get, set,
reset, init/deinit, or unknown. The role picks the member's coherent hook
(enable → write 1, is-ready → read, …). See @ref symbol_groups.

## Model {#gloss_model}

In Resect's MVC framing: a data store plus the types that describe it, with
no behavior beyond (de)serialization. Resect has exactly two — the
[artifact database](@ref gloss_artifact_db) and the
[project](@ref gloss_project). See @ref architecture.

## Object group {#gloss_object_group}

A family of firmware [symbols](@ref gloss_symbol) that are member functions of
the same peripheral "object," recognized by a verb-anchored parse of each
name (the tokens before the first role verb are the object) — e.g.
`LL_RCC_LSI_Enable` / `_Disable` / `_IsReady`. A coincidental shared prefix
never forms a group: a name with no recognized verb is dropped, not
guessed at. Members get coherent hooks that
share a [group scope](@ref gloss_group_scope), and are hooked together when any
one of them faults. Non-comms symbols only. See @ref symbol_groups.

## Orchestrator {#gloss_orchestrator}

`EmulationOrchestrator`: the façade that composes an
[engine](@ref gloss_engine) with the emulation, analysis, and synthesis
workflows, and emits events. It owns no persistent data. The third
long-lived object of the architecture, alongside the two
[controllers](@ref gloss_controller). See @ref orchestrator_engine.

## Overlay {#gloss_overlay}

Collective name for the per-project hook-selection maps stored
on the [project](@ref gloss_project): [overrides](@ref gloss_override),
[preferences](@ref gloss_preference), override scopes,
[bindings](@ref gloss_binding), and the per-group `groupOverrides`
(force/suppress an [object group](@ref gloss_object_group)). See
@ref hook_overlays.

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
`classifier:rule-<N>-<name>` (the seeder, naming the rule that fired),
`llm:<modelTag>` (the synthesizer's LLM fallback), `llm:auto-tune-r<N>`
(an auto-tune custom-hook round), or `user`. Lets you judge how much to
trust the binding's fidelity estimate.

## RAG {#gloss_rag}

Retrieval-augmented generation: before asking the LLM to write a hook,
Resect retrieves the most relevant chunks of project documents and
[Ghidra extraction](@ref gloss_ghidra_extraction) facts from a per-project
index (`rag_index.db`) and puts them in the prompt.

## Reachable-code coverage {#gloss_reachable_coverage}

[Coverage](@ref gloss_coverage) measured against the set of functions
reachable from what actually executed, rather than against the whole
[call graph](@ref gloss_call_graph). Reported with its *headroom* — the count
of reachable-but-unexecuted symbols — which is the "can this even improve?"
signal. Under-counts, because the graph has direct calls only, so the raw
`executed / total` number stays the cross-version baseline. See
@ref autotune_decisions.

## Recent call sequence {#gloss_recent_call_sequence}

The last 16 function *entries* before a run ended, oldest→newest, with
consecutive repeats collapsed (`` `sym` (×N) ``). Captured in a ring buffer
on the emulation controller from Renode's function-entry events and cleared at
the top of each synthesizer iteration, so it describes the final iteration.
Where the [halt point](@ref gloss_halt_point) says *where* execution stopped,
this says *how it got there*. See @ref autotune_decisions.

## Recommendation {#gloss_recommendation}

One typed, machine-applicable change proposed by the LLM during
[auto-tune](@ref gloss_autotune): set/clear an
[override](@ref gloss_override), set a [preference](@ref gloss_preference),
generate a custom hook, adjust the iteration cap, or force/clear a whole
[object group](@ref gloss_object_group). Each carries a one-sentence
rationale, and the kinds plus their required fields are enforced by the
response schema. See @ref autotune and @ref autotune_decisions.

## Renode {#gloss_renode}

The open-source systems emulator (from Antmicro) that actually runs the
firmware. Resect drives a patched portable Renode build in server mode and
installs [hooks](@ref gloss_hook) with its `AddHookAtSymbol` command.

## Review policy {#gloss_review_policy}

The [auto-tune](@ref gloss_autotune) engine's pluggable answer to the
question of who approves the LLM's
[recommendations](@ref gloss_recommendation). The CLI uses accept-all; the
UI presents them for human review, with an accept-all mode of its own
chosen at session start. See @ref autotune.

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
UI's sink feeds the inline `AutoTunePanel` in the Synthesize tab — and a UI
session composes both through `MultiSink` (`UiAutoTuneSink` +
`AutoTuneReportSink`), so it writes the same per-round report files the CLI
does. See @ref autotune.

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

## Termination reason {#gloss_termination_reason}

The named stopping condition recorded on every
[synthesis](@ref gloss_synthesis) result and [manifest](@ref gloss_manifest):
`cleanRun`, `symbolExhausted`, `forcedOverrideFailed`, `maxIterations`, or
`cancelled`. It exists so that `failedSymbol` can mean *only* "a real
[symbol](@ref gloss_symbol) faulted and its candidates ran out" — hitting the
iteration cap is control flow, not a fault, and leaves that field null. The
[auto-tune](@ref gloss_autotune) loop's own endings are separate
(`AutoTuneStopReason`). See @ref synthesis.

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

In [auto-tune](@ref gloss_autotune), warm start is a per-session knob
(`--warm-start` / a dialog switch, default off): on, each round is seeded
with the previous round's resolved hooks; off (cold start), every round
re-synthesizes from the overlay set alone, keeping rounds independent and
comparable. See @ref autotune.

## Wrapper skip {#gloss_wrapper_skip}

Forcing an *executed* caller — typically an `*_Init`/`*Config` function with
unreached callees — to return 0, so its whole body is skipped. The move of
last resort when a busy-wait is inlined in the caller and there is no leaf
function left to hook: it trades the coverage inside the wrapper for
everything after it. Today it is always a blunt `return 0`, side effects
included. See @ref autotune_decisions.
