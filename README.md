# Resect

Resect builds high-fidelity emulators for embedded firmware. Given an ELF and
a Renode platform description (`.repl`), it **classifies** the firmware's
hardware-dependent functions, **scores** candidate Python hooks for each one,
**generates** new hooks on demand with a local LLM, and **applies** them
inside Renode through an iterative synthesis loop that records every
decision in a per-run manifest. The output is a `.emu` project file
carrying the resolved hooks, the scoped Python globals, the call graph,
and the manifest — which downstream tooling (including the in-app LLM
advisor) reads back to recommend changes for the next run.

The orchestrator runs entirely in-process — there is no Python backend. The
engine packages (`renode`, `resect_callgraph`, `resect_hooks`,
`resect_signatures`) are hosted on the project's package repository and
resolve as ordinary versioned dependencies. Renode itself runs as a
**server** that Resect connects to over the network — a container in the
compose stack, or a portable build you start in server mode.

The quickest way to run any of it:

```bash
just install # once: pull the LLM models
just run_cli    # containerized CLI + Renode + Ollama
just run_gui    # containerized GUI on your own display 
```

See [Docker](#docker) below.

What's optional, gated behind module flags:

- **`MODULE_LLM_HOOKGEN`** — RAG-grounded LLM hook generation + the Last Run
  recommendation panel. Backed by any reachable Ollama daemon (the compose
  service, a remote host, or a local install) — detection is HTTP-first.
- **`MODULE_GHIDRA`** — Ghidra-driven decompilation and ABI signature
  extraction that grounds the classifier and the LLM prompts.
- **`MODULE_COMMS_BUS`** — UDP-virtualized I²C / SPI / UART buses.
- **`MODULE_MEMORY_MAP`** — Apply a memory-map snapshot before emulation
  starts (planned; the UI slot exists, the runtime is in progress).

What's always on: the iterative synthesizer, the call-graph viewer, the
hook catalog, the artifact database, the per-symbol forced-override path,
and the .emu / .resc export flow.

Three surfaces — a Flutter desktop GUI (the primary interface), a CLI, and
an HTTP API server — all backed by the same orchestrator.

Supported targets: ARM (via `arm-none-eabi-objdump`) and x86_64 (via stock
`objdump`).

## Documentation

The architecture documentation lives in [docs/pages/](docs/pages/) as a
Doxygen site — start with `docs/pages/index.md`, or generate the browsable
version with `doxygen docs/Doxyfile` (from the repo root) and open
`docs/generated/html/index.html`. Those pages are the source of truth for
the architecture: design changes are written there first, then the code is
aligned to them.

## Architecture

```
┌───────────────────────┐  ┌───────────────────────┐  ┌───────────────────────┐
│   Flutter GUI         │  │   HTTP API server     │  │   CLI                 │
│   (emulator_ui)       │  │   (bin/server.dart)   │  │   (bin/cli.dart)      │
└───────────┬───────────┘  └───────────┬───────────┘  └───────────┬───────────┘
            │                          │                          │
            └──────────────────────────┴──────────────────────────┘
                                       │
                       ┌───────────────▼──────────────────────────────┐
                       │   emulator_orchestrator                      │
                       │   • Workflows (emulator / analysis /         │
                       │     emulation / synthesizer)                 │
                       │   • Engine abstraction                       │
                       │     (CallGraphSource, EmulationController,   │
                       │      EngineLifecycle, TraceSource)           │
                       │   • Artifact DB (Drift)  ← single write      │
                       │     boundary; inlines hook imports on insert │
                       │   • Per-project RAG (Drift + 768-dim         │
                       │     embeddings via Ollama nomic-embed-text)  │
                       │   • Comms bus (UDP forwarder; MODULE_COMMS)  │
                       │   • Hook classifier + binding seeder         │
                       │   • LLM hook generator (MODULE_LLM_HOOKGEN)  │
                       │   • Synthesis manifest sink                  │
                       │     → <project>/manifests/<run_id>.json      │
                       └───────────┬───────────────┬──────────────────┘
                                   │               │
                  ┌────────────────┼───────────────┼────────────────┐
                  │                │               │                │
        ┌─────────▼─────────┐  ┌───▼──────────┐ ┌──▼─────────────┐ ┌▼──────────────┐
        │  Dart engine      │  │  Ollama      │ │  Ghidra        │ │  Renode       │
        │  (in-process)     │  │              │ │  (optional)    │ │  server       │
        │  • renode         │  │  HTTP NDJSON │ │                │ │  (1.16.x      │
        │  • resect_callgr. │  │  container   │ │  subprocess    │ │   patched,    │
        │  • resect_hooks   │  │  or local    │ │  Java 21+      │ │   for the     │
        │  • resect_signat. │  │  MODULE_LLM_ │ │  MODULE_GHIDRA │ │   scope arg)  │
        │       │           │  │  HOOKGEN     │ │                │ │               │
        │       │           │  └──────────────┘ └────────────────┘ └───────▲───────┘
        │       └────────────── TCP (RENODE_HOST:RENODE_PORT) ─────────────┘
        └───────────────────┘
```

Without `MODULE_LLM_HOOKGEN` and `MODULE_GHIDRA`, Resect still
synthesizes firmware — with fewer candidate sources (no LLM-authored
hooks) and less grounding (no Ghidra decompilation in the RAG /
classifier).

### Workspace layout

This is a [Dart workspace](https://dart.dev/tools/pub/workspaces) with two
packages sharing one dependency resolution:

```
resect/                              ← workspace root
├── pubspec.yaml                     ← workspace manifest (2 packages)
├── pubspec_overrides.yaml           ← (optional, gitignored) routes an
│                                       engine package to a local checkout
├── compose.yml                      ← the container stack (init / normal profiles)
├── docker/                          ← Dockerfile, entrypoint, env files, config
├── workdir/                         ← bind-mounted into containers as /workdir
│
├── emulator_orchestrator/           ← pure Dart package (no Flutter)
│   ├── bin/
│   │   ├── cli.dart                 ← CLI entry
│   │   └── server.dart              ← HTTP API server entry
│   └── lib/
│       ├── api/                     ← shelf_router HTTP routes
│       ├── config/                  ← Component / module gates, config schema
│       ├── core/                    ← app paths, shared constants
│       ├── data/
│       │   ├── database/            ← Drift/SQLite artifact store
│       │   ├── models/              ← Emulator, CallGraph, HookBinding,
│       │   │                          HookDecisionState, SynthesisManifest,
│       │   │                          LastRunInsight, …
│       │   └── repositories/        ← .emu file persistence
│       ├── services/                ← domain services by area:
│       │   ├── analysis/            ← FidelityCalculator, call-graph guard
│       │   ├── comms/               ← comms classification + merge
│       │   ├── external/            ← installers (Ollama, Ghidra)
│       │   ├── hooks/               ← HookCatalog, HookBindingSeeder,
│       │   │                          HookTestHarness, artifact library
│       │   ├── llm/                 ← LlmClient, LlmHookGenerator,
│       │   │                          LastRunInsightService
│       │   ├── quality/             ← hook-quality harness
│       │   └── rag/                 ← RagIndex
│       └── orchestrator/
│           ├── emulation_orchestrator.dart
│           ├── auto_tune_engine.dart / auto_tune_report_writer.dart
│           ├── comms/               ← UDP forwarder + device handlers
│           ├── engine/              ← engine abstraction + Dart impl
│           │   └── dart/            ← the renode client, in-process
│           └── workflows/           ← emulator / analysis /
│                                      emulation / synthesizer
│
└── emulator_ui/                     ← Flutter Linux desktop app
    └── lib/
        ├── main.dart
        ├── core/                    ← theme, paths
        ├── providers/               ← Riverpod state
        └── presentation/
            ├── dialogs/             ← Hook Database, LLM Hook Gen,
            │                          System Config, Vagrant Test, …
            ├── screens/
            │   ├── library/         ← projects + documents + RAG card
            │   ├── callgraph/       ← graph viewer + metadata sidebar
            │   ├── comms/           ← bus classifier + virtualization
            │   ├── synthesize/      ← pre-flight + run + Last Run card
            │   └── publish/         ← .resc export
            └── widgets/
```

### Engine packages

Four engine packages are consumed as **hosted** dependencies from
`https://nexus.medmakers.io/repository/pub`, declared with ordinary version
constraints in `emulator_orchestrator/pubspec.yaml`:

| Package | Version | Role |
|---|---|---|
| `renode` | 2.2.2 | Renode client: monitor commands, state / function-call / unhandled-access events, hook installation. Connects to a Renode **server**; `RenodeProcess` (used only by the hook-quality harness) can also launch a local portable. |
| `resect_callgraph` | ^1.0.0 | Builds call graphs from ELF files via `arm-none-eabi-objdump` / `objdump`. Direct calls only. |
| `resect_hooks` | ^1.5.1 | Typed hook builders (`returnHook`, `readHook`, `writeHook`, `incrementHook`, `i2cReadHook`, `i2cWriteHook`, `uartReadHook`, `uartWriteHook`, `spiReadHook`, `spiWriteHook`), the embedded Python modules, and the UDP wire format. |
| `resect_signatures` | ^1.0.0 | Ghidra-backed function signatures, decompilation, and data symbols. Feeds the hook classifier and the LLM prompt composers. |

`iomt_lab_lints` supplies the shared `analysis_options` as a dev dependency.

A clean `dart pub get` needs no sibling checkouts. **Publishing a change to
one of these packages requires a version bump** — the repository serves
immutable versions, so re-pushing the same version silently changes nothing.

For local co-development, drop a git-ignored `pubspec_overrides.yaml` at the
workspace root:

```yaml
dependency_overrides:
  resect_hooks:
    path: ../hooks-dart
```

Note that an override affects only your host build: the container images
build from `pubspec.lock` and always resolve the hosted versions. `run.sh`
has an embedded-modules drift check that keeps the mirrored Python sources
in sync with the canonical `.py` files, but it greps the overrides file for
`hooks:` — the `resect_hooks:` spelling above does not trip it.

## Concepts

The synthesizer reads a single consolidated **layered hook overlay** for
each firmware. The layers (highest priority first):

1. **Forced overrides.** User pinned a specific artifact for a symbol from
   the Call Graph tab's metadata sidebar. Pre-seeded; fail-fatal if the
   firmware faults at the symbol again.
2. **Comms-bus hooks.** Symbols the user mapped to a virtualized protocol
   (`i2c` / `spi` / `uart`) in the Comms tab. Pre-seeded with the protocol
   scope.
3. **Warm-start (resolved) hooks.** Bodies that survived a previous
   successful synthesis. Pre-seeded; the loop can still iterate past them
   if a new unhandled access shows up elsewhere.
4. **Fidelity-scored bindings.** Per-project, per-symbol records carrying
   `{artifactId, fidelity 0.0–1.0, provenance, scope}`. Drive the
   synthesizer's candidate-sort order — when an unhandled-access pause
   fires, candidates are tried highest-confidence-first.
5. **Preference hints.** Soft re-order signal — promote a specific
   artifact to "try first" for a symbol the user hasn't otherwise touched.

The projection that exposes all five to the synthesizer lives in
[`hook_decision_state.dart`](emulator_orchestrator/lib/data/models/hook_decision_state.dart);
it's the same projection the pre-synthesis report renders and the
manifest builder extends with runtime outcomes.

The rest of this section walks through what each piece is and where it
lives.

### Emulator (`.emu` file)

JSON project file persisted under
`~/.config/call_graph_viewer/projects/`. Carries the ELF + `.repl` paths,
emulation config (start/end symbols, pauseOnUnhandled), per-symbol forced
overrides + scopes, comms classification + per-protocol config,
fidelity-scored hook bindings (`hook_bindings`), cached call graph, last
synthesis result, the last-run LLM advisory (`last_run_insight`), and a
small list of attached documents. The cached call graph is bound to its
firmware by an `elfHash` SHA-256 stamp, validated at project open/save and
at auto-tune start — a mismatched or unstamped graph is rejected (logged)
and re-extracted.

### Hook catalog

A registry of typed builders defined in
`emulator_orchestrator/lib/services/hooks/hook_catalog.dart`, wired through
to hooks-dart's [`simple_hooks.dart`](https://github.com/IoMT-Lab/hooks-dart/blob/main/lib/src/simple_hooks.dart).
The default templates seeded into the artifact DB are eight bodies:
`return`, `read`, `write`, and `increment`, each in a `value=0` and a
`value=1` preset. Each carries an intrinsic-score floor — 0.0 for bare
returns, 0.1 for stateful counters, 0.2 for read/write — that the
synthesizer falls back to when no per-symbol binding exists.

### Hook classifier (seven rules)

Runs on project open via `HookBindingSeeder.seedBindingsForElf` over the
firmware's Ghidra decompilation rows — **from the GUI only**; the CLI never
runs this pass, and the container images ship no Ghidra, so headless sessions
have no classifier bindings (see `docs/pages/pre-synthesis.md`). Each rule
that matches inserts a hook binding at a seeded fidelity:

| Rule | Pattern | Hook chosen | Seeded fidelity |
|---|---|---|---|
| `rule-1-empty-or-void-return` | Empty body or bare `return;` | `returnHook(0)` | 0.25 |
| `rule-2-return-literal` | `return <int literal>;` | `returnHook(value)` | 0.25 |
| `rule-3-counter-global` | Returns a tick / counter / `ms_count` global | `incrementHook` | 0.5 |
| `rule-4-chip-config-global` | Returns a clock-named global | `returnHook(64_000_000)` | 0.5 |
| `rule-5-busy-ready-flag` | Masked status read; name matches `busy` (→0) or `ready`/`active`/`valid` (→1) | `returnHook(0 or 1)` | 0.5 |
| `rule-6-pure-peripheral-writes` | Pure peripheral writes; `void` return | `returnHook(0)` | 0.5 |
| `rule-7-hal-polling-loop` | `HAL_GetTick()` + `do { … } while(…)`; returns `HAL_StatusTypeDef` | `returnHook(0)` (HAL_OK) | 0.5 |

Each binding records its provenance as `classifier:rule-N-...`. The
synthesizer's iteration sort weights the binding's fidelity over the
artifact's intrinsic-score floor (`COALESCE(binding.fidelity,
intrinsicScore)`). The classifier itself doesn't depend on
`MODULE_LLM_HOOKGEN`. With `MODULE_GHIDRA` off, fewer decompiled
bodies are available and the classifier skips symbols it has no
source for.

### Forced overrides + scope

From the Call Graph tab's metadata sidebar, any non-comms symbol can be
pinned to a specific hook artifact, with an optional Renode `scope`
string. Scope is auto-suggested from the symbol name (`LL_RCC_HSE_Enable`
→ `HSE`) and editable. Scoped hooks share a per-scope Python `globals()`
inside Renode, so e.g. a stateful `write` to one symbol becomes visible
to a stateful `read` on another in the same scope. **The scope arg is
only honored by the patched Renode portable**
(`renode_1.16.1+20260512gitf8adfbff0-portable` or newer); stock 1.16.0
silently drops it.

Fidelity-scored bindings carry the same `scope` field; when a binding
wins a candidate selection, its scope is sent to Renode alongside the
hook body.

### Comms-bus virtualization (`MODULE_COMMS_BUS`)

A separate tab classifies call-graph functions as `i2c` / `spi` / `uart`
/ `unclassified` using token-aware name matching. For each protocol you
can configure a UDP port + device handler (built-in: zero-fill, random;
or external by leaving the in-process server off and binding your own
listener). Toggling Virtualize on stages bus hooks (read / write /
return0 fill-in for role-less symbols) that forward each transaction
over UDP. The external-listener pattern is what enables driving a real
sensor over an FT232H.

### LLM hook generation + RAG (`MODULE_LLM_HOOKGEN`)

When the classifier doesn't produce a binding for a symbol, the user can
ask the LLM to write one. End-to-end:

1. **RAG retrieval.** Top-K cosine-rank chunks from the per-project
   `<project>/rag_index.db` (SQLite, 768-dim float32 embeddings from
   Ollama `nomic-embed-text`). Sources indexed: Ghidra decompilations,
   data types, data symbols, memory map, attached user docs, and hook
   bodies. The symbol's own decompilation is pinned at rank 0.
2. **Prompt composition** in
   [`LlmHookGenerator`](emulator_orchestrator/lib/services/llm/llm_hook_generator.dart):
   the platform facts (ELF machine, `.repl` verbatim, firmware symbol
   list) + the retrieved chunks + a system prompt that documents the
   IronPython 2.7 + Renode hook conventions.
3. **LLM call** via
   [`LlmClient.generate`](emulator_orchestrator/lib/services/llm/llm_client.dart)
   against Ollama at `LLM_OLLAMA_HOST`. Model from `LLM_MODEL`, default
   `gemma4:e4b`.
4. **Validation** via the
   [Hook Test Harness](#hook-test-harness) — every classifier-matched
   and LLM-generated hook runs against a minimal Cortex-M4 firmware
   that calls the hook ten times and reports the returned values.
5. **Insert** at the DB write boundary as a new artifact + a binding
   with provenance `harness+judge` (when a judge model approved) or
   `llm:<modelTag>` (when only the harness gated it).

Two trigger paths:

- **User-driven**, via "Generate" in the Hook Database dialog for a
  selected symbol.
- **Synthesizer-driven**, when iteration exhausts every existing
  candidate for a faulting symbol. The manifest tags the resulting
  decision as `llm_on_demand`.

### Hook test harness

[`hook_test_harness.dart`](emulator_orchestrator/lib/services/quality/hook_test_harness.dart)
spawns Renode on port 5099, loads a base64-embedded minimal Cortex-M4
firmware (in `test_harness_assets.dart`), applies a candidate hook to
`main`, runs `main()` ten times, and reads 10 uint32 results from
memory. A harness PASS requires the bootstrap to reach `halt_loop`
cleanly, no unhandled accesses, no timeout, and every result satisfies
the hook's `HookInvariant` (e.g. strictly increasing for counter hooks,
all-zero for `return 0`).

Three consumers: classifier post-validation, LLM-output validation, and
the "Test this hook" button in the Hook Database dialog.

### Synthesizer

Drives Renode with `pauseOnUnhandled=true`. On the first iteration the
synthesizer pre-seeds layers 1–3 of the overlay (forced overrides +
comms hooks + warm-start). Each iteration:

1. Reset Renode (`Clear`), wait briefly, reload firmware + apply the
   accumulated hook set.
2. Start emulation. Wait up to 30 s for either an unhandled-access
   pause (advance one symbol) or a 30 s clean run (declare success).
3. On pause: a failed **forced override** stops the run outright; a
   faulting member of a recognized **object group** force-installs the
   whole group's coherent hooks under one shared scope and re-runs.
4. Otherwise sort layer-4 bindings + artifact-DB candidates by
   `COALESCE(binding.fidelity, intrinsicScore)`; apply the
   highest-scoring candidate that hasn't been tried; record the
   decision; go to next iteration.
5. As soon as no *specialized* candidate remains (nothing scoring ≥ 0.5 —
   i.e. no classifier binding or user replacement), the LLM authors a fresh
   hook for the symbol (`llm_on_demand`), which is seeded at 0.5 and sorts
   to the front on the retry. Generic templates are still tried, but only
   after that.
6. If candidates and the LLM both run out, the synthesizer reports the
   `failedSymbol`.

Every exit records a **termination reason** — `cleanRun`,
`symbolExhausted`, `forcedOverrideFailed`, `maxIterations`, `cancelled` — and
only the two symbol-level reasons set `failedSymbol`. The iteration cap is
500 headless and is a stopping condition of last resort: normal runs end on a
30 s clean execution or on candidate exhaustion. Results also carry where
execution actually got to (`finalExecutionSymbol`) and the last 16 function
entries (`recentExecutionTrace`), which is what the auto-tune loop reasons
over. Details: `docs/pages/synthesis.md`.

### Synthesis manifest

Per-run JSON record at `<project>/manifests/<run_id>.json` (mirrored
into the `.emu` file's `synthesis_result` field for warm-start
carry-over). Schema-versioned — `manifest_version` is 2 today.

Per-run fields: `elf_hash`, `elf_file_name`, `synthesizer_run_id`
(ISO-8601 timestamp), `result {success, totalIterations,
durationSeconds}`, `decisions[]`, `failed_symbol`, `last_pause_symbol`,
`termination_reason`, `final_execution_symbol`, `recent_execution_trace`,
plus the enrichment fields `metrics` (fidelity + hooked/intact/degraded
counts) and `executed_symbols`.

Per-decision fields: `symbol`, `applied_hook {artifact_id, body_hash,
scope}`, `decision_kind` (one of `forced_override`, `comms`,
`warm_start`, `binding`, `iteration_fallback`, `llm_on_demand`,
`group_override`),
`decision_source` (provenance string), `fidelity_at_decision`,
`iteration_index`, `previous_attempts[]`, optional `llm_invocation`
telemetry.

The manifest is the canonical record of what synthesis did to the
firmware. The schema is stable enough that downstream tools — and the
in-app LLM advisor — can consume it deterministically.

### Last Run insights

After a synthesis run completes, the Synthesize tab's Last Run card can
ask the LLM for a 1–3 sentence advisory grounded in the manifest + the
current `HookDecisionState` + a slice of the call graph around the
last-applied or failed symbol. Cached against the run's
`synthesizer_run_id` on the `.emu` so reopening the project re-renders
without re-running the LLM; the cache goes stale the moment a new run
produces a new id.

The advisory picks the **smallest installed Ollama model** (by on-disk
size, via `/api/tags`) rather than the hook-gen default — the task is
short enough that a 0.5B–1B model runs in seconds. Gated on
`MODULE_LLM_HOOKGEN`; with the module off, the Last Run card still
shows the fidelity headline and replaces the recommendation panel
with a one-line hint pointing at the module flag.

### Auto-tune (closed loop)

`AutoTuneEngine` runs synthesis repeatedly and lets the LLM tune the overlay
between rounds: **recommend → review → filter no-ops → author → apply →
re-synthesize → snapshot**. It is plain Dart with two injected seams — a
*review policy* (accept-all headless; the GUI picks interactive or
accept-all at session start) and a *sink* — so both surfaces run the same
loop and write the same per-round report files; the GUI additionally feeds
its inline auto-tune panel (`auto_tune_panel.dart`) from the same events.

Sessions are **cold-start by default**: every round re-synthesizes from
the overlay set, so rounds stay independent and comparable. The
warm/cold-start knob (`--warm-start` on the CLI, a switch in the GUI's
session config) instead seeds each round with the previous round's
resolved hooks. Rounds are also **measured and reverted**: a round whose
executed-symbol coverage collapses below half the session's best is
reverted wholesale, and the session ends holding the best round's
overlays.

Each round the model gets a fixed-order evidence packet: where execution
stopped and the recent call path into it, raw *and* reachable-set coverage
(the headroom number answers "can this improve at all?"), what each nearby
hook actually does and whether it took effect, the annotated coverage
frontier, the real artifact catalog, and the last three rounds' trajectory.
Its reply is forced into typed recommendations by a per-round JSON schema
built from live catalog ids and call-graph symbols — narrowed further on
escalation rounds (only stalled wrapper callers) and error-sink rounds (only
symbols on the path into the handler) — then validated again at parse time
and in the engine.

Two detectors stop a session that has stopped earning its rounds: repeated
failure at the same symbol with nothing new tried, and coverage stagnation
(which escalates once, then finishes with `noCoverageProgress`). Headless
sessions write `round_NN.md`, `round_NN_manifest.json`, `round_NN_trace.txt`
(the exact prompt), and `summary.md`.

Full detail: `docs/pages/autotune.md` (machinery) and
`docs/pages/autotune-decisions.md` (the decision).

### Fidelity metrics

Coverage + subgraph + intact / degraded / hooked counts, computed from
the call graph and the executed-symbol trace by
[`FidelityCalculator`](emulator_orchestrator/lib/services/analysis/fidelity_calculator.dart).
The pre-synthesis report uses **call-graph reachability** (forward BFS
from `Reset_Handler` / `main`) to split "uncovered" symbols into
*reachable-but-unbound* (synthesis can fault here) and *unused code*
(dead, never executed) — the latter doesn't affect synthesis outcomes
but inflates a naive uncovered count, so it gets visualized as a faint
tail on the coverage bar.

### Artifact database

SQLite store via Drift at
`~/.config/call_graph_viewer/artifact_library/artifacts.db`. Schema
includes hook artifacts, intrinsic-score floors, firmware-image
registrations, hook bindings, and the Ghidra-extracted tables
(decompilations, data types, data symbols, memory maps, call-graph
cache) when `MODULE_GHIDRA` is on.

**The DB is the single enforcement boundary for hook import inlining.**
Every write (`addArtifact` / `updateArtifactData`) routes hook bodies
through `substituteImport` before insert, so every read returns
deployable Python — Renode's IronPython never sees a bare `import
set_return_value` line that would crash the engine. Legacy raw-import
rows from earlier builds get rewritten by a one-shot
`migrateLegacyHookBodies` pass that runs on project open.

## Modules

Four optional modules, configured via the System Configuration dialog
(Tools menu) or directly in `resect.config`. Each is independently
toggleable; the synthesizer and the basic catalog flow work with all
four off.

| Module | configKey | What it enables | External deps |
|---|---|---|---|
| LLM Hook Generation | `MODULE_LLM_HOOKGEN` | RAG indexing, LLM-driven hook generation (user-triggered + synthesizer iteration-fallback), the Last Run advisory panel | A reachable Ollama daemon (`LLM_OLLAMA_HOST` — the compose service, a remote host, or a local install) + an inference model (default `gemma4:e4b`) + `nomic-embed-text` for embeddings |
| Ghidra Analysis | `MODULE_GHIDRA` | Ghidra-headless decompilation, function signatures, ABI argument tables, enriched call-graph extraction. Feeds both the classifier and the LLM prompt composer. | Ghidra install + Java 21+ |
| Communication Bus Virtualization | `MODULE_COMMS_BUS` | The Comms tab; UDP-virtualized I²C / SPI / UART hooks and the in-process UDP forwarder | None (built-in) |
| Memory Map Initialization | `MODULE_MEMORY_MAP` | Apply a memory-map snapshot (constants + regions) before emulation starts | Planned — UI slot exists, runtime is partial |

LLM and Ghidra are independent. Running LLM_HOOKGEN without GHIDRA
works but produces less-grounded prompts (no Ghidra decompilation in
the RAG retrieval). Running GHIDRA without LLM_HOOKGEN gives you a
richer classifier-binding pool but no LLM-authored fallback hooks.

The System Configuration dialog can also install the underlying
binaries for modules that ship an installer (`MODULE_LLM_HOOKGEN`
installs Ollama and pulls models; `MODULE_GHIDRA` installs Ghidra and
verifies Java).

## Tabs (UI tour)

| Tab | Surface |
|---|---|
| **LIBRARY** | Recent projects, new project dialog, open/save/close. Attached-documents card with add/open/remove. RAG index status card (chunks indexed, last built, source drift detection) when `MODULE_LLM_HOOKGEN` is on. |
| **CALL GRAPH** | Force-directed graph viewer, symbols list with search, metadata sidebar with function instructions, FORCE OVERRIDE dropdown + SCOPE field, PREFERRED HOOK dropdown, calls/called-by navigation. **Refresh / Regenerate** two-mode button: Refresh reuses the cached Ghidra call graph; hold Shift to flip to Regenerate, which invalidates the cache and re-extracts from scratch. |
| **COMMS** | Class selector (i2c/spi/uart/unclassified) with per-class counts. Two-pane main: collapsible call-graph tree on the left (per-class), Python interface config + staged-hooks readout on the right. Virtualize toggle, fill-in-return0 checkbox. (Gated on `MODULE_COMMS_BUS`.) |
| **SYNTHESIZE** | **Pre-synthesis review** card on the idle view: stats (Ready / Hook candidates / Needs discovery) over a coverage bar with two-tone amber (high vs low-fidelity bindings), reachable-grey, and dead-code-grey tail. Saved-hook tags inline. Run config below (Start From, Stop At, Memory Map, Pause on unhandled). Run Synthesis button + live event stream. Auto-tune runs in an **inline auto-tune panel** with a per-round trajectory chart, session view, and optional per-round recommendation review. After a run, a visually distinct **Last Run card** with the fidelity headline, iter / duration, and (with `MODULE_LLM_HOOKGEN` on) a streaming LLM recommendation panel. |
| **PUBLISH** | Export the current resolved-hooks set to a standalone Renode `.resc` script. |

Tools → System Configuration edits `resect.config` for paths (Flutter
SDK, objdump variants, engine dir, Renode binary/portable), the Renode
port and log path, the Ollama host and model, the Ghidra directory,
module flags, and per-module binary detection + install. The autosave
preference lives in the separate Preferences dialog.

## Requirements

**Container path:** 
- Docker 
- Docker Compose
- just (https://just.systems/man/en/)
- Nothing else — Renode, Ollama, the models, objdump, and Resect all come from images.

## Docker <a id="docker"></a>

One compose file, one Resect image, three modes. The `normal` profile pairs
the `resect` container (which carries both the compiled CLI and the Flutter
app; the entrypoint's `cli` / `gui` / `vnc` argument picks one) with a Renode
server and a healthchecked Ollama. The one-shot model pull (`gemma4:e4b` +
`nomic-embed-text`) lives in the separate `init` profile — run it once via
`just install` or the LLM features have no models. App state persists in the
`resect-state` volume.

```bash
just install     # FIRST RUN: creates ./workdir, pulls the LLM models
just build       # build the resect image locally (else it pulls)
just run_cli     # interactive CLI shell in /workdir
just run_gui     # GUI on your own display (Wayland/X11 passthrough)
just run_vnc     # GUI on a virtual display; VNC client → localhost:5900
just stop        # stop both profiles, keep volumes
just clean       # WIPES the resect-state volume contents (app data)
just uninstall   # down -v — DESTROYS the state + model volumes
```

The run scripts pass `HOST_UID`/`HOST_GID` through, so files written into
`./workdir` (projects, manifests, auto-tune reports) stay owned by you —
and `workdir/` is gitignored apart from the shipped example files. The
in-image `resect.config` points Resect at the `renode` and `ollama` services;
it deliberately contains no Ghidra, so headless runs have no decompilation —
see `docs/pages/containers.md`.

## Install

### Automated

```bash
git clone git@github.com:IoMT-Lab/resect.git
cd resect

# Containers (no host toolchain needed):
just install    # once — model pull
just run_cli


## Run

```bash
just run_cli            # container: cli version of the app
just run_gui            # container: same app, on your own display
just run_cli            # container: same app, over VNC on localhost:5900
```

## CLI

Headless commands for scripting:

```bash
resect-cli --help                             # in the container
```

Available commands:

| Command | Purpose |
|---|---|
| `create` | Create a new `.emu` project file |
| `callgraph` | Generate a call graph from an ELF |
| `synthesize` | Run the automated hook synthesizer |
| `autotune` | Run a closed-loop LLM auto-tune session with per-round reports |
| `fidelity` | Compute fidelity metrics for a hook set |
| `export` | Export an emulator to a standalone `.resc` script |

Each command has `--help` for its options. Global flags:

| Flag | Purpose |
|---|---|
| `--engine-dir <path>` | Path to `emulation_engine/`. Accepted, but unused on the emulation path — Renode is reached at `RENODE_HOST:RENODE_PORT` |

A full auto-tune session, end to end:

```bash
resect-cli create --name aya --elf fw.elf --repl board.repl -o aya.emu
resect-cli synthesize --elf fw.elf --repl board.repl --save-emulator aya.emu
resect-cli autotune --emu aya.emu --max-rounds 10
# then read autotune_reports/<timestamp>/summary.md
```

## HTTP API

```bash
dart run emulator_orchestrator:server --port 8080
```

| Method | Path | Description |
|---|---|---|
| GET | `/status` | Orchestrator state + loaded emulator info |
| POST | `/emulator` | Create a new emulator |
| GET | `/emulator` | Get the current loaded emulator |
| POST | `/callgraph` | Generate a call graph from an ELF |
| POST | `/synthesizer/run` | Run synthesis (`maxIterations` default 500) |
| GET | `/synthesizer/events` | SSE stream of synthesis progress |
| POST | `/emulation/start` | Start emulation |
| POST | `/emulation/stop` | Reset emulation |
| POST | `/fidelity` | Compute fidelity metrics |

All endpoints accept/return JSON. See
`emulator_orchestrator/lib/api/api_server.dart` for request/response
schemas.

## Development

### Co-developing an engine package

The engine packages resolve from the hosted repository, so a normal clone
builds with no siblings present. To work on one, clone it next to resect and
add a git-ignored `pubspec_overrides.yaml` at the workspace root as shown
above:

```
~/Development/
├── resect/
├── renode-dart/       → package `renode`
├── callgraph-dart/    → package `resect_callgraph`
├── hooks-dart/        → package `resect_hooks`
└── signatures-dart/   → package `resect_signatures`
```

Two rules for shipping such a change: **bump the package version** before
publishing (the repository serves immutable versions, so re-pushing the same
number propagates nothing), then update the constraint in
`emulator_orchestrator/pubspec.yaml` and relock. Container images build from
`pubspec.lock` and ignore your override entirely.

If you change `hooks-dart/lib/resources/python/*.py`, regenerate the
embedded mirror with:

```bash
cd ~/Development/hooks-dart
dart run tool/gen_system_modules.dart
```

`./run.sh` runs `--check` on every launch and surfaces drift before the
app starts.

### Tests

```bash
dart test emulator_orchestrator
cd emulator_ui && flutter test
```

### Drift codegen

After changes to `artifact_database.dart`:

```bash
cd emulator_orchestrator
dart run build_runner build --delete-conflicting-outputs
```

### Static analysis

```bash
dart analyze emulator_orchestrator
flutter analyze emulator_ui
```

### Release builds

```bash
# Flutter GUI
cd emulator_ui
flutter build linux --release         # → build/linux/x64/release/bundle/

# CLI as self-contained executable
cd ..
dart compile exe emulator_orchestrator/bin/cli.dart -o resect-cli
```

### Headless verification tools

A handful of stand-alone scripts under `emulator_orchestrator/tool/`:

| Tool | Purpose |
|---|---|
| `headless_synthesis.dart` | Drives the synthesizer workflow against a real `.emu` project from a Dart main, without booting the Flutter UI. Useful for reproducing crashes and CI smoke checks. |
| `verify_legacy_migration.dart` | Scans the user's artifact DB for legacy raw-import rows and confirms `migrateLegacyHookBodies` rewrites them idempotently. |
| `verify_substituted_hook_in_renode.dart` | Loads a migrated hook from the DB and runs it through the Hook Test Harness against the real firmware to confirm Renode executes it without `ImportException`. |
| `dump_llm_prompt.dart` | Composes and prints the LLM hook-generation prompt for a chosen symbol — useful for tuning the prompt without round-tripping through the GUI. |
| `sweep_v2.dart` | Bulk-runs the LLM generator across a random sample of symbols and reports classifier verdicts + LLM telemetry. |

## Data storage

| Path | Contents |
|---|---|
| `~/.config/call_graph_viewer/projects/<project>.emu` | Saved `.emu` project file. Its cached call graph carries an `elfHash` SHA-256 stamp binding it to the firmware, validated at open/save/auto-tune — mismatches are logged and the graph regenerated |
| `~/.config/call_graph_viewer/projects/<project>/manifests/<run_id>.json` | Per-run synthesis manifest (when the project lives in a project subdirectory) |
| `~/.config/call_graph_viewer/projects/<project>/rag_index.db` | Per-project RAG index (`MODULE_LLM_HOOKGEN`) |
| `~/.config/call_graph_viewer/projects/<project>/documents/` | User-attached documents that travel with the .emu |
| `~/.config/call_graph_viewer/artifact_library/artifacts.db` | SQLite artifact DB (global, includes Ghidra tables when `MODULE_GHIDRA` is on) |
| `~/.config/call_graph_viewer/projects/<project>/autotune_reports/<timestamp>/` | Per-round auto-tune reports: `round_NN.md`, `round_NN_manifest.json`, `round_NN_trace.txt` (the exact prompt sent), `summary.md` |
| `<repo>/resect.config` | Local paths, ports, autosave preference, module flags (gitignored) |
| `/tmp/renode_logs/renode.log` | Renode stdout/stderr capture |

In a container, `$HOME/.config` is symlinked to `/static_home` — the
`resect-state` volume — so the paths above persist across container runs, and
`/workdir` is the `./workdir` bind mount the host can read.

## Technology stack

| Layer | Technology |
|---|---|
| GUI | Flutter 3.x (Linux desktop) |
| State management | Riverpod 2.x |
| Engine | `renode` + `resect_callgraph` + `resect_hooks` + `resect_signatures` (all in-process), driving a Renode server over TCP |
| Hook templates | hooks-dart `simple_hooks.dart` builders + import inlining at the DB write boundary |
| Comms forwarder | hooks-dart UDP wire format (binary protocol; one-hot selector for i2c/spi/uart) |
| Artifact storage | Drift 2.x + SQLite3 |
| RAG index | Drift 2.x + SQLite3, 768-dim float32 embeddings (Ollama `nomic-embed-text`) |
| LLM | Ollama HTTP `/api/generate` (NDJSON streaming); default model `gemma4:e4b`, smallest-installed selection for advisory tasks |
| Ghidra | Headless `analyzeHeadless` invocation; output parsed and cached in `ghidra_*` Drift tables |
| HTTP API | shelf + shelf_router |
| Graph viewer | graphview 1.2 |
| Call graph extraction | `arm-none-eabi-objdump` (ARM) / `objdump` (x86_64) + optional Ghidra enrichment |

## License

TBD
