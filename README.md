# Resect

Resect builds high-fidelity emulators for embedded firmware. Given an ELF and
a Renode platform description (`.repl`), it **classifies** the firmware's
hardware-dependent functions, **scores** candidate Python hooks for each one,
**generates** new hooks on demand with a local LLM, and **applies** them
inside Renode through an iterative synthesis loop that records every
decision in a per-run manifest. The output is a `.emu` project file with the
resolved hooks, scoped Python globals, the call graph, and the manifest a
downstream tool (or another LLM round) can read back to suggest the next
iteration.

The orchestrator runs entirely in-process — there is no Python backend.
[`renode-dart`](https://github.com/IoMT-Lab/renode-dart),
[`callgraph-dart`](https://github.com/IoMT-Lab/callgraph-dart), and
[`hooks-dart`](https://github.com/IoMT-Lab/hooks-dart) are embedded as
sibling Dart packages and launch a Renode portable subprocess directly.

What's optional, gated behind module flags:

- **`MODULE_LLM_HOOKGEN`** — RAG-grounded LLM hook generation + the Last Run
  recommendation panel. Backed by a local Ollama install.
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
        │  (in-process):    │  │  (local      │ │  (subprocess;  │ │  portable     │
        │  • renode-dart    │  │   HTTP /     │ │   MODULE_      │ │  (1.16.x;     │
        │  • callgraph-dart │  │   NDJSON;    │ │   GHIDRA)      │ │   patched     │
        │  • hooks-dart     │  │   MODULE_    │ │  Java 21+      │ │   build for   │
        │  • signatures     │  │   LLM_…)     │ │                │ │   scope arg)  │
        │       │           │  └──────────────┘ └────────────────┘ └───────────────┘
        │       └──────────────────── subprocess ──────────────────────┘
        └───────────────────┘
```

Boxes drawn with dashed lines in your head — Ollama and Ghidra — are
optional. Resect synthesizes firmware without them, just with less
grounding context and no LLM-authored hooks.

### Workspace layout

This is a [Dart workspace](https://dart.dev/tools/pub/workspaces) with two
packages sharing one dependency resolution:

```
resect/                              ← workspace root
├── pubspec.yaml                     ← workspace manifest (2 packages)
├── pubspec_overrides.yaml           ← (optional, gitignored) routes
│                                       hooks/renode/callgraph/signatures/
│                                       lints to local sibling checkouts
├── install.sh                       ← one-time setup
├── run.sh                           ← launches the Flutter app
├── resect.config                    ← paths/ports/prefs/module flags
│                                       (gitignored; managed by Tools →
│                                       System Configuration or install.sh)
├── emulation_engine/                ← Renode portables + LFS-tracked
│                                       legacy binary; no Python backend
│
├── emulator_orchestrator/           ← pure Dart package (no Flutter)
│   ├── bin/
│   │   ├── cli.dart                 ← CLI entry
│   │   └── server.dart              ← HTTP API server entry
│   └── lib/
│       ├── api/                     ← shelf_router HTTP routes
│       ├── config/                  ← Component / module gates
│       ├── data/
│       │   ├── database/            ← Drift/SQLite artifact store
│       │   ├── models/              ← Emulator, CallGraph, HookBinding,
│       │   │                          HookDecisionState, SynthesisManifest,
│       │   │                          LastRunInsight, …
│       │   ├── repositories/        ← .emu file persistence
│       │   └── services/            ← HookCatalog, HookClassifier,
│       │                              HookBindingSeeder, HookTestHarness,
│       │                              LlmClient, LlmHookGenerator,
│       │                              LastRunInsightService, RagIndex,
│       │                              SignaturesService, FidelityCalculator
│       └── orchestrator/
│           ├── emulation_orchestrator.dart
│           ├── comms/               ← UDP forwarder + device handlers
│           ├── engine/              ← engine abstraction + Dart impl
│           │   └── dart/            ← wraps renode-dart in-process
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

### Sibling Dart packages

Five siblings of resect are consumed as git-pinned dependencies (or
locally-pinned for the unreleased one) in `emulator_orchestrator/pubspec.yaml`:

| Package | Role |
|---|---|
| [`renode-dart`](https://github.com/IoMT-Lab/renode-dart) | Wraps the Renode portable binary as a Dart subprocess; speaks Renode's control protocol. |
| [`callgraph-dart`](https://github.com/IoMT-Lab/callgraph-dart) | Builds call graphs from ELF files via `arm-none-eabi-objdump` / `objdump`. |
| [`hooks-dart`](https://github.com/IoMT-Lab/hooks-dart) | Typed hook builders (`returnHook`, `readHook`, `writeHook`, `incrementHook`, `i2cReadHook`, `i2cWriteHook`, `uartReadHook`, `uartWriteHook`) and the UDP wire format. |
| `signatures` | Ghidra-backed function signature + ABI argument extraction. Consumed by the LLM hook generator's prompt composer. **Local pin only** — not yet published to a public remote; wire it in via `pubspec_overrides.yaml`. |
| [`lints-dart`](https://github.com/IoMT-Lab/lints-dart) | Shared analysis_options. |

For local development against any of them, drop a `pubspec_overrides.yaml`
at the workspace root:

```yaml
dependency_overrides:
  hooks:
    path: ../hooks-dart
  renode:
    path: ../renode-dart
  callgraph:
    path: ../callgraph-dart
  signatures:
    path: ../signatures
  iomt_lab_lints:
    path: ../lints-dart
```

`run.sh` detects this and runs hooks-dart's `tool/gen_system_modules.dart
--check` on every launch so the embedded Python-module mirror never drifts
from the canonical `.py` sources.

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
small list of attached documents.

### Hook catalog

A registry of typed builders defined in
`emulator_orchestrator/lib/data/services/hook_catalog.dart`, wired through
to hooks-dart's [`simple_hooks.dart`](https://github.com/IoMT-Lab/hooks-dart/blob/main/lib/src/simple_hooks.dart).
The default templates seeded into the artifact DB are the two legacy
`return-N` bodies, two catalog `returnHook(N)` bodies, and `read` /
`write` / `increment` variants (both `value=0` and `value=1` presets),
ten templates total. Each carries an intrinsic-score floor — 0.0 for
bare returns, 0.1 for stateful counters, 0.2 for read/write — that the
synthesizer falls back to when no per-symbol binding exists.

### Hook classifier (seven rules)

Runs on project open via `HookBindingSeeder.seedBindingsForElf` over the
firmware's Ghidra decompilation rows. Each rule that matches inserts a
hook binding at a seeded fidelity:

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
intrinsicScore)`). Classifier behaviour is independent of `MODULE_LLM`
— with `MODULE_GHIDRA` off, the classifier has fewer decompiled bodies
to consume and silently skips symbols it can't see into.

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
wins a candidate selection, its scope rides into Renode with the hook.

### Comms-bus virtualization (`MODULE_COMMS_BUS`)

A separate tab classifies call-graph functions as `i2c` / `spi` / `uart`
/ `unclassified` using token-aware name matching. For each protocol you
can configure a UDP port + device handler (built-in: zero-fill, random;
or external by leaving the in-process server off and binding your own
listener). Toggling Virtualize on stages bus hooks (read / write /
return0 fill-in for role-less symbols) that forward each transaction
over UDP. The external-listener pattern is what enables driving a real
sensor over an FT232H — see `emulation_engine/run_client.py` for a
starting point.

### LLM hook generation + RAG (`MODULE_LLM_HOOKGEN`)

When the classifier doesn't produce a binding for a symbol, the user can
ask the LLM to write one. End-to-end:

1. **RAG retrieval.** Top-K cosine-rank chunks from the per-project
   `<project>/rag_index.db` (SQLite, 768-dim float32 embeddings from
   Ollama `nomic-embed-text`). Sources indexed: Ghidra decompilations,
   data types, data symbols, memory map, attached user docs, and hook
   bodies. The symbol's own decompilation is pinned at rank 0.
2. **Prompt composition** in
   [`LlmHookGenerator`](emulator_orchestrator/lib/data/services/llm_hook_generator.dart):
   the platform facts (ELF machine, `.repl` verbatim, firmware symbol
   list) + the retrieved chunks + a system prompt that documents the
   IronPython 2.7 + Renode hook conventions.
3. **LLM call** via
   [`LlmClient.generate`](emulator_orchestrator/lib/data/services/llm_client.dart)
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

[`hook_test_harness.dart`](emulator_orchestrator/lib/data/services/hook_test_harness.dart)
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
3. On pause, sort layer-4 bindings + artifact-DB candidates by
   `COALESCE(binding.fidelity, intrinsicScore)`; apply the
   highest-scoring candidate that hasn't been tried; record the
   decision; go to next iteration.
4. If a symbol exhausts every candidate AND `MODULE_LLM_HOOKGEN` is
   on, the LLM generates a fresh hook (`llm_on_demand`).
5. If candidates and the LLM both run out, the synthesizer reports the
   `failedSymbol`.

Default iteration cap is 10. The cap is a defensive backstop, not the
normal termination — successful runs exit on 30 s clean execution or
on candidate exhaustion. (A redesign that replaces the global cap with
per-symbol exhaustion is in TODO.txt.)

### Synthesis manifest

Per-run JSON record at `<project>/manifests/<run_id>.json` (mirrored
into the `.emu` file's `synthesis_result` field for warm-start
carry-over). Schema-versioned — `manifest_version` is 1 today.

Per-run fields: `elf_hash`, `elf_file_name`, `synthesizer_run_id`
(ISO-8601 timestamp), `result {success, totalIterations,
durationSeconds}`, `decisions[]`, `failed_symbol`.

Per-decision fields: `symbol`, `applied_hook {artifact_id, body_hash,
scope}`, `decision_kind` (one of `forced_override`, `comms`,
`warm_start`, `binding`, `iteration_fallback`, `llm_on_demand`),
`decision_source` (provenance string), `fidelity_at_decision`,
`iteration_index`, `previous_attempts[]`, optional `llm_invocation`
telemetry.

The manifest is built so downstream tools (or an LLM round) can
consume it deterministically — it's the canonical record of "what
synthesis did to this firmware."

### Last Run insights

After a synthesis run completes, the Synthesize tab's Last Run card can
ask the LLM for a 1–3 sentence advisory grounded in the manifest + the
current `HookDecisionState` + a slice of the call graph around the
last-applied or failed symbol. Cached against the run's
`synthesizer_run_id` on the `.emu` so reopening the project re-renders
without re-running the LLM; the cache goes stale the moment a new run
produces a new id.

The advisory deliberately picks the **smallest installed Ollama model**
(by on-disk size, via `/api/tags`) rather than the hook-gen default —
the task is short enough that a 0.5B–1B model runs in seconds. Hidden
behind `MODULE_LLM_HOOKGEN`; without the module, the Last Run card
still shows the fidelity headline and surfaces an "enable the module
for recommendations" hint.

### Fidelity metrics

Coverage + subgraph + intact / degraded / hooked counts, computed from
the call graph and the executed-symbol trace by
[`FidelityCalculator`](emulator_orchestrator/lib/data/services/fidelity_calculator.dart).
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
| LLM Hook Generation | `MODULE_LLM_HOOKGEN` | RAG indexing, LLM-driven hook generation (user-triggered + synthesizer iteration-fallback), the Last Run advisory panel | Ollama running locally + an inference model (default `gemma4:e4b`) + `nomic-embed-text` for embeddings |
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
| **SYNTHESIZE** | **Pre-synthesis review** card on the idle view: stats (Ready / Hook candidates / Needs discovery) over a coverage bar with two-tone amber (high vs low-fidelity bindings), reachable-grey, and dead-code-grey tail. Saved-hook tags inline. Run config below (Start From, Stop At, Memory Map, Pause on unhandled). Run Synthesis button + live event stream. After a run, a visually distinct **Last Run card** with the fidelity headline, iter / duration, and (with `MODULE_LLM_HOOKGEN` on) a streaming LLM recommendation panel. |
| **PUBLISH** | Export the current resolved-hooks set to a standalone Renode `.resc` script. |

Tools → System Configuration edits `resect.config` for paths (Flutter
SDK, objdump variants, engine dir, Renode binary), the HTTP API port,
the autosave preference, module flags, and per-module binary detection
+ install.

## Requirements

| Dependency | Purpose |
|---|---|
| Flutter SDK (Dart >= 3.9) | GUI + Dart toolchain |
| clang, cmake, ninja-build | Flutter Linux desktop build |
| libgtk-3-dev, liblzma-dev, pkg-config | GTK runtime + build glue |
| gcc-arm-none-eabi | `arm-none-eabi-objdump` for ARM call graphs |
| git-lfs | Fetches the stock Renode portable |
| Renode portable (patched) | Required for scope-arg support — patched build available from the project maintainers |
| **Ollama (optional)** | `MODULE_LLM_HOOKGEN`. Linux install via the standard installer; pull at least one inference model and `nomic-embed-text` |
| **Ghidra + Java 21+ (optional)** | `MODULE_GHIDRA`. Headless analysis for signatures + decompilation |

Optional: VirtualBox + Vagrant for the CI/CD test harness; opt-in via
`./install.sh --with-vagrant-test`.

## Install

### Automated

```bash
git clone git@github.com:IoMT-Lab/resect.git
cd resect
./install.sh                  # or: ./install.sh --with-vagrant-test
```

`install.sh` provisions system packages, ensures Flutter is on PATH (or
clones a stable SDK to `~/Development/flutter`), runs `git lfs pull` for
the Renode portable, and writes `resect.config` with detected paths.
Module installers (Ollama / Ghidra) are runnable from Tools → System
Configuration after the GUI is up.

### Manual

```bash
# 1. System packages
sudo apt-get update
sudo apt-get install -y \
  clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  gcc-arm-none-eabi git git-lfs curl

# 2. Flutter SDK (git install — required for Linux desktop)
git clone https://github.com/flutter/flutter.git -b stable ~/Development/flutter
echo 'export PATH="$HOME/Development/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter precache
flutter config --enable-linux-desktop

# 3. Renode binary (LFS)
cd resect/emulation_engine
git lfs install && git lfs pull

# 4. Patched Renode portable
#    Drop the renode_1.16.1+...-portable directory into emulation_engine/
#    and point RENODE_BIN / RENODE_PORTABLE at it via resect.config or
#    Tools → System Configuration.

# 5. (Optional) Ollama for MODULE_LLM_HOOKGEN
curl -fsSL https://ollama.com/install.sh | sh
ollama pull gemma4:e4b
ollama pull nomic-embed-text

# 6. (Optional) Ghidra for MODULE_GHIDRA — install via Tools →
#    System Configuration once the GUI is up.

# 7. Dart workspace
cd ..
dart pub get
```

Verify:

```bash
flutter doctor -v
dart analyze emulator_orchestrator
```

## Run

```bash
./run.sh
```

`run.sh` runs Drift codegen (`build_runner build`) if the generated files
are missing, runs hooks-dart's embedded-modules drift safeguard when a
local override is active, then launches `flutter run -d linux`. No
Python server is involved. Exit Flutter normally with `q`.

## CLI

Headless commands for scripting. Run from the workspace root:

```bash
dart run emulator_orchestrator:cli --help
```

Available commands:

| Command | Purpose |
|---|---|
| `create` | Create a new `.emu` project file |
| `callgraph` | Generate a call graph from an ELF |
| `synthesize` | Run the automated hook synthesizer |
| `fidelity` | Compute fidelity metrics for a hook set |
| `export` | Export an emulator to a standalone `.resc` script |

Each command has `--help` for its options. Global flags:

| Flag | Purpose |
|---|---|
| `--engine-dir <path>` | Path to `emulation_engine/` (auto-detected if omitted) |
| `--backend-url <url>` | Connect to an existing engine instance (skips auto-start) |

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
| POST | `/synthesizer/run` | Run synthesis (`maxIterations` default 10) |
| GET | `/synthesizer/events` | SSE stream of synthesis progress |
| POST | `/emulation/start` | Start emulation |
| POST | `/emulation/stop` | Reset emulation |
| POST | `/fidelity` | Compute fidelity metrics |

All endpoints accept/return JSON. See
`emulator_orchestrator/lib/api/api_server.dart` for request/response
schemas.

## Development

### Sibling-checkout workflow

Clone the sibling packages next to resect (under the same parent
directory by default):

```
~/Development/
├── resect/
├── renode-dart/
├── callgraph-dart/
├── hooks-dart/
├── signatures/
└── lints-dart/
```

Then drop `pubspec_overrides.yaml` at the resect workspace root as shown
above. The override file is gitignored.

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
| `~/.config/call_graph_viewer/projects/<project>.emu` | Saved `.emu` project file |
| `~/.config/call_graph_viewer/projects/<project>/manifests/<run_id>.json` | Per-run synthesis manifest (when the project lives in a project subdirectory) |
| `~/.config/call_graph_viewer/projects/<project>/rag_index.db` | Per-project RAG index (`MODULE_LLM_HOOKGEN`) |
| `~/.config/call_graph_viewer/projects/<project>/documents/` | User-attached documents that travel with the .emu |
| `~/.config/call_graph_viewer/artifact_library/artifacts.db` | SQLite artifact DB (global, includes Ghidra tables when `MODULE_GHIDRA` is on) |
| `<repo>/resect.config` | Local paths, ports, autosave preference, module flags (gitignored) |
| `/tmp/renode_logs/renode.log` | Renode stdout/stderr capture |

## Technology stack

| Layer | Technology |
|---|---|
| GUI | Flutter 3.x (Linux desktop) |
| State management | Riverpod 2.x |
| Engine | renode-dart + callgraph-dart + hooks-dart + signatures (all in-process) wrapping a Renode portable subprocess |
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
