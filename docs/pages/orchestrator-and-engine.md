# The Orchestrator and the Engine {#orchestrator_engine}

@ref architecture names three long-lived objects. Two are the controllers;
this page explains the third — `EmulationOrchestrator`, the
[orchestrator](@ref gloss_orchestrator) — and the
[engine](@ref gloss_engine) underneath it. These two words get used
loosely in conversation; this page gives them exact meanings.

## The engine: four interfaces

The engine is not one class. It is a set of four capability interfaces,
all in `emulator_orchestrator/lib/orchestrator/engine/`:

| Interface | Job |
|---|---|
| `EngineLifecycle` | Start and stop the emulator process. |
| `EmulationController` | Load firmware; run, pause, resume, reset; define [hooks](@ref gloss_hook) and anchor them at [symbols](@ref gloss_symbol). |
| `CallGraphSource` | Produce the [call graph](@ref gloss_call_graph) for a firmware binary. |
| `TraceSource` | Stream which functions execute while the firmware runs. |

An *engine implementation* is anything that provides these four. Resect
has one: `DartEngine` (`engine/dart/`), which drives the pinned portable
[Renode](@ref gloss_renode) build. Every Renode monitor command — loading
a platform, `AddHookAtSymbol`, reading the trace — happens inside the
`engine/dart/` directory and nowhere else.

That gives the layer its one rule: **only engine implementations talk to
Renode.** The rest of the system programs against the four interfaces, so
swapping the emulator (or adding a second engine) means writing one new
`engine/<name>/` directory, not touching the workflows above it.

@note **Deviation from the current code.**
**Today:** four data services import `package:renode` directly —
`hook_catalog.dart`, `hook_classifier.dart`, `hook_test_harness.dart`, and
`hook_progress_runner.dart` (all under
`emulator_orchestrator/lib/data/services/`) — so the "only engines talk to
Renode" rule leaks. Separately, the two `CallGraphSource` implementations
are wired unevenly: the UI picks `GhidraCallGraphSource` or the
objdump-based `DartCallGraphSource` by configuration
(`callGraphSourceProvider` in `emulator_ui/lib/providers/app_providers.dart`),
while the CLI always uses objdump.
**Planned:** recorded as [known debts](@ref known_debts) — not scheduled
in a roadmap phase.
**Why:** the four services are genuinely engine-bound, so the leak is
tolerated until a second engine makes it a real problem; the call-graph
unevenness means the UI and CLI can produce different call graphs for the
same project, which matters and should eventually be unified.

## The orchestrator: workflows over an engine

`EmulationOrchestrator`
(`emulator_orchestrator/lib/orchestrator/emulation_orchestrator.dart`)
composes one engine with the *workflows* — the multi-step procedures that
drive an emulation — and emits events that views subscribe to. The
workflows are:

- **Emulation** — start the engine, load firmware, run/pause/resume/reset.
- **Analysis** — generate and lay out the call graph.
- **Synthesis** — the iterative hook-substitution loop
  (`SynthesizerWorkflow`, described in @ref synthesis).

The defining property of the orchestrator is what it does *not* have: it
owns **no persistent data**. Hook bodies belong to
[model #1](@ref model_artifacts); per-project state belongs to
[model #2](@ref model_projects). That is why the architecture calls it a
façade rather than a third [controller](@ref gloss_controller) — a
controller exists to guard a [model](@ref gloss_model), and the
orchestrator has none to guard.

## How the three peers divide the work

For one synthesis run, the division looks like this:

    ProjectController          ArtifactController         EmulationOrchestrator
    ─────────────────          ──────────────────         ─────────────────────
    supplies the overlays  ─▶                         ─▶  runs the synthesizer
    (overrides, prefs,         supplies hook bodies       against the engine
    bindings) as inputs        by artifact id
                                                          returns the result
    persists the result    ◀─  stores any hooks the   ◀─  and the manifest
    and snapshots              LLM authored mid-run

    EmulationOrchestrator
            │  (the four engine interfaces)
            ▼
        DartEngine ──▶ Renode

The orchestrator receives overlay maps as *arguments* and returns results;
it never reads or writes a `.emu` file. It asks the ArtifactController for
bodies by id; it never runs SQL of its own.

@note **Deviation from the current code.**
**Today:** the project lifecycle lives *inside* the orchestrator — the
fourth workflow, `EmulatorWorkflow`
(`emulator_orchestrator/lib/orchestrator/workflows/emulator_workflow.dart`),
wraps `.emu` load/save. And the heavy flows bypass the seams:
`SynthesizerWorkflow` and `AutoTuneEngine` query `ArtifactDatabase`
directly instead of going through a controller.
**Planned:** `EmulatorWorkflow` is renamed and carved out as
`ProjectController`, a peer beside the orchestrator (@ref phase_p5);
artifact access folds behind the ArtifactController (@ref phase_p3).
**Why:** while project persistence sits inside the orchestrator, "the
orchestrator owns no data" is false and the UI/CLI must each invent their
own project handling around it — which is exactly how the current
scattered lifecycle (see [Gap 1](@ref gap_project_controller)) happened.

## One naming warning

`AutoTuneEngine` (@ref autotune) is **not** an engine in this page's
sense. It implements no capability interface and never touches Renode; it
is the driver of the auto-tune loop, and its name predates this
vocabulary. When these docs say "the engine" without qualification, they
mean the emulation engine defined above.

## In short

The engine is four interfaces (`EngineLifecycle`, `EmulationController`,
`CallGraphSource`, `TraceSource`) with one Renode-backed implementation,
and only engine implementations talk to Renode. The orchestrator composes
an engine with the emulation, analysis, and synthesis workflows, owns no
persistent data, and works on inputs from — and returns results to — the
two controllers.
