# Where Things Live {#where_things_live}

The code is organized **by layer** — all the [models](@ref gloss_model)
together, all the services together, all the orchestrator code together. That's
good for "show me every service" and awkward for "show me everything about
auto-tune," because one feature is spread across `data/models/`, `services/`,
and `orchestrator/`. This page is the index that bridges the gap: pick a
process, get the files.

All paths are under `emulator_orchestrator/lib/` unless noted. The UI
(`emulator_ui/lib/`) sits on top and calls into these.

## The layers, in one line each

- `data/models/` — pure data: the [project](@ref gloss_project)
  (`emulator.dart`), [call graph](@ref gloss_call_graph), manifests,
  recommendations, bindings. No behavior.
- `data/database/` — the SQLite [artifact database](@ref gloss_artifact_db).
- `data/repositories/` — `.emu` project file load/save.
- `services/` — the logic layer, grouped by capability
  (`hooks/ llm/ rag/ analysis/ quality/ comms/ external/`). See
  @ref contributing for the folder rules.
- `orchestrator/` — coordination: the [engine](@ref gloss_engine) interfaces
  + Renode impl (`engine/`), the workflows, and the loops.
- `core/`, `config/` — app paths/constants and the `resect.config` system.

## Building and annotating the call graph

**Heads-up:** this is the most cross-cutting feature — it touches building the
graph, computing coverage over it, *and* assembling the LLM's view of it. No
single folder holds it all. The narrative is @ref pre_synthesis.

| Concern | File |
|---|---|
| The graph itself (data) | `data/models/call_graph.dart`, `symbol.dart`, `graph_point.dart` |
| Build it (objdump) | `orchestrator/engine/dart/dart_call_graph_source.dart` |
| Build it (Ghidra) | `orchestrator/engine/dart/ghidra_call_graph_source.dart` |
| Generate + lay out | `orchestrator/workflows/analysis_workflow.dart` |
| Read/cache | `services/analysis/call_graph_service.dart` |
| Coverage [frontier](@ref gloss_frontier) | `services/analysis/coverage_frontier.dart` |
| [Fidelity](@ref gloss_fidelity) over the graph | `services/analysis/fidelity_calculator.dart` |
| Annotate for the LLM (halt point, recent call sequence, frontier notes) | `services/llm/last_run_insight_service.dart` |
| Reachable-set / coverage headroom | `FidelityCalculator.reachableFromEntries` |

## A single synthesis run

See @ref synthesis for the narrative.

| Concern | File |
|---|---|
| The loop | `orchestrator/workflows/synthesizer_workflow.dart` |
| Group-override decision (pure) | `planGroupOverride` in the same file |
| Where execution got to + the recent call trace | `orchestrator/engine/dart/dart_emulation_controller.dart` |
| Termination reasons | `SynthesisTerminationReason` in `data/models/synthesis_manifest.dart` |
| LLM fallback hook authoring | `services/llm/llm_hook_generator.dart` |
| Build the [manifest](@ref gloss_manifest) | `orchestrator/manifest_builder.dart` |
| Result / manifest models | `data/models/synthesizer_result.dart`, `synthesis_manifest.dart` |

## The auto-tune loop

See @ref autotune for the machinery and @ref autotune_decisions for the
decision.

| Concern | File |
|---|---|
| The loop engine | `orchestrator/auto_tune_engine.dart` |
| Stop / stagnation detectors + no-op filter | `orchestrator/auto_tune_progress.dart` |
| Headless report [sink](@ref gloss_sink) | `orchestrator/auto_tune_report_writer.dart` |
| Ask the LLM for [recommendations](@ref gloss_recommendation); build the response schema | `services/llm/recommendation_service.dart` |
| Compose the round's evidence sections | `services/llm/last_run_insight_service.dart` |
| Sampling profiles per task | `services/llm/llm_profiles.dart` |
| Round-over-round metric delta | `services/analysis/fidelity_delta.dart` |
| Apply recommendations to [overlays](@ref gloss_overlay) | `orchestrator/recommendation_overlay_applier.dart` |
| Config / snapshot / recommendation models | `data/models/auto_tune_config.dart`, `round_snapshot.dart`, `recommendation.dart` |

## Hooks and the artifact library

See @ref hook_lifecycle and @ref symbol_groups.

| Concern | File |
|---|---|
| Hook body templates | `services/hooks/hook_catalog.dart` |
| Rule-based classifier | `services/hooks/hook_classifier.dart` |
| [Object-group](@ref gloss_object_group) classifier | `services/hooks/symbol_group_classifier.dart` |
| Bulk binding seeding | `services/hooks/hook_binding_seeder.dart` |
| Scope inference | `services/hooks/scope_suggester.dart` |
| The DB-backed pool | `services/hooks/artifact_library_service.dart` + `data/database/artifact_database.dart` |
| Hook-quality subsystem (unwired) | `services/quality/*` |

## Comms virtualization

See @ref comms_virtualization.

| Concern | File |
|---|---|
| Symbol classifier | `services/comms/comms_classifier.dart` |
| UDP bus + handlers + hook build | `orchestrator/comms/` |

## Running firmware (the engine)

See @ref orchestrator_engine.

| Concern | File |
|---|---|
| The four capability interfaces | `orchestrator/engine/*.dart` |
| Renode-backed implementation | `orchestrator/engine/dart/*.dart` |
| Run/pause/reset workflow | `orchestrator/workflows/emulation_workflow.dart` |
| The façade | `orchestrator/emulation_orchestrator.dart` |

## The project (`.emu`)

See @ref model_projects.

| Concern | File |
|---|---|
| The model | `data/models/emulator.dart` |
| Load / save / export | `data/repositories/emulator_repository.dart` |
| Lifecycle workflow (today) | `orchestrator/workflows/emulator_workflow.dart` |

## LLM and RAG infrastructure

| Concern | File |
|---|---|
| Ollama client | `services/llm/llm_client.dart` |
| Sampling profiles | `services/llm/llm_profiles.dart` |
| [RAG](@ref gloss_rag) index + chunker | `services/rag/rag_index.dart`, `rag_chunker.dart` |
| Ghidra signatures + installers | `services/external/*` |

## The two surfaces

- **CLI:** `bin/cli.dart` — see @ref cli.
- **HTTP API:** `bin/server.dart` + `api/api_server.dart`.

## Packaging and the container stack

Not under `emulator_orchestrator/` — these live at the repository root. See
@ref containers.

| Concern | File |
|---|---|
| The stack (services, volumes, profiles) | `compose.yml` (+ `.env` defaults) |
| The one image (CLI + GUI) | `docker/Dockerfile` |
| Container user + mode dispatch (cli / gui / vnc) | `docker/entrypoint.sh` |
| Display env for native GUI / headless runs | `docker/gui.env`, `docker/non_gui.env` |
| In-image config | `docker/resect.config` |
| Install / build / run / stop / clean / uninstall wrappers | `scripts/*.sh` |

Both construct the same objects and call the same code as the UI — if a feature
works in one surface but not the other, that's a bug, not a design choice.
