# Before Synthesis: From ELF to Hook Candidates {#pre_synthesis}

@ref synthesis starts with the firmware already running and a set of
[hooks](@ref gloss_hook) already in hand. This page covers everything that
happens *before* that first iteration: extracting the
[call graph](@ref gloss_call_graph), annotating it, classifying the
functions in it, and turning those classifications into the ranked hook
candidates the [synthesizer](@ref gloss_synthesizer) will draw from.

Get this stage wrong and synthesis still runs — it just runs stupidly,
grinding `return 0` templates into functions whose behavior nobody
characterized. Everything here exists to make sure that by the time the
firmware boots, Resect already has an opinion about each function.

## The five things that must exist first

    ELF + .repl
        │
        ├─▶ 1. Firmware registration ──▶ ELF hash, symbol rows, default templates
        ├─▶ 2. Call-graph extraction ──▶ nodes + caller→callee edges
        ├─▶ 3. Ghidra extraction ─────▶ signatures, decompiled C, data symbols  (optional)
        ├─▶ 4. Classification ────────▶ comms classes, object groups, template matches
        └─▶ 5. Binding + candidates ──▶ per-symbol ranked hook list
                                             │
                                             ▼
                                         @ref synthesis

Steps 1 and 2 are unconditional. Step 3 is a module. Step 4 is three
different classifiers that answer three different questions. Step 5 is
where the answers become something the synthesizer can act on.

## Step 1 — Register the firmware

`ArtifactLibraryService.processElfFile`
(`emulator_orchestrator/lib/services/hooks/artifact_library_service.dart`)
runs first, and it does four things worth knowing:

1. **Hashes the ELF** (SHA-256). That [ELF hash](@ref gloss_elf_hash) is
   the key every firmware fact in the
   [artifact database](@ref gloss_artifact_db) is stored under, so facts
   survive renaming or moving the binary.
2. **Records the symbol names** from the call graph against that hash.
3. **Seeds the default hook templates** (`ensureDefaultTemplates`) if they
   aren't in the database yet — eight bodies, described below.
4. **Back-fills [intrinsic scores](@ref gloss_intrinsic_score)**
   (`ensureIntrinsicScores`) on any artifact row that doesn't have one.

The eight seeded templates come from `HookCatalog.system()`
(`services/hooks/hook_catalog.dart`), built through the
`resect_hooks` package's Python builders (@ref workspace_layout):

| Template | Body does | Intrinsic score |
|---|---|---|
| `return` 0 / 1 | Sets the return register and returns immediately. | 0.0 |
| `read` 0 / 1 | Reads a scoped Python global, returns it (default 0/1). | 0.2 |
| `write` 0 / 1 | Writes 0/1 into a scoped global, returns 0. | 0.2 |
| `increment` 0 / 1 | Increments a scoped global and returns it. | 0.1 |

The intrinsic score is a property of the *body*, not of any symbol: "how
useful is this hook in general?" A bare `return 0` scores 0.0 — its only
virtue is that it doesn't crash. User-authored reusable hooks get 0.3,
user-authored replacements for a specific symbol get 0.5. That floor is
what candidate ranking falls back on when nothing better is known about a
symbol (step 5).

## Step 2 — Extract the call graph

`DartCallGraphSource`
(`orchestrator/engine/dart/dart_call_graph_source.dart`) shells out to
objdump through the `resect_callgraph` package — `arm-none-eabi-objdump`
for ARM binaries, stock `objdump` for x86-64, both paths read from
`resect.config`. Each graph node carries two facts:

- **`numInstructions`** — actually the function's byte size; objdump gives
  size, not an instruction count, and the field name predates the
  substitution.
- **`calledSymbols`** — a map of callee name → call-site count. These are
  the edges everything downstream reasons over.

Two properties of this graph matter enormously later, and both are
limitations rather than features:

- **Direct calls only.** A call through a function pointer, a vtable, or an
  interrupt vector does not appear. So the graph *under*-approximates
  reachability — which is exactly why @ref autotune_decisions reports raw
  `executed / total` coverage as the honest baseline and treats the
  reachable-set number as a supplementary signal.
- **Names, not addresses.** A callee that isn't itself a node (a PLT stub,
  an unresolved import) still shows up as an edge. The prompt composer
  flags those explicitly so the LLM doesn't try to hook something that
  isn't a function.

There is a second implementation, `GhidraCallGraphSource`, which reads the
richer graph out of the [Ghidra extraction](@ref gloss_ghidra_extraction)
cache. The UI selects between the two by configuration; the CLI is
hard-wired to objdump (see [known debts](@ref known_debts)).

The finished graph is cached on the [project](@ref gloss_project) as
`cachedCallGraph`, and every later stage — coverage math, the
[frontier](@ref gloss_frontier), the LLM's symbol enum — reads that one
copy, so the whole session reasons over identical edges. Reads of the
cache are gated on a content-hash match: every graph is stamped with its
source ELF's SHA-256, and `services/analysis/call_graph_guard.dart`
(`sha256OfFile` / `callGraphMatchesElf` / `ensureCallGraphForElf`)
validates the stamp against the firmware actually in use. The CLI's
`autotune`, the UI session resolver (`resolveSessionCallGraph`),
`callgraphProvider`, and `openEmulator` all go through it; a mismatched or
unstamped graph is logged and regenerated rather than trusted.

## Step 3 — Ghidra extraction (the annotation layer)

This is the optional step that makes the difference between "Resect knows
this function's name" and "Resect knows what this function does."

`SignaturesService.extractFor` (`services/external/signatures_service.dart`)
runs Ghidra headlessly over the ELF — 30 seconds to a couple of minutes,
cached afterwards — and writes six tables into the artifact database, keyed
by ELF hash:

| What | Used by |
|---|---|
| Function signatures (return type, ABI arg list) | The classifier's rules 6/7; the LLM hook generator's prompt |
| Decompiled C, one body per function | The [classifier](@ref gloss_classifier); [RAG](@ref gloss_rag) retrieval |
| Data symbols (name, address, type, size) | The classifier's rule 3 (a returned identifier must be a real data symbol) |
| Data types / structs | The hook generator's prompt |
| Memory map | Memory-map application (module in progress) |
| Call graph | `GhidraCallGraphSource` |

Gated by `MODULE_GHIDRA` in `resect.config`. Without it, the tables are
empty — the classifier has nothing to read, and so does no work. That
single consequence is the most important thing on this page; it is spelled
out in the deviation note at the end.

## Step 4 — Three classifiers, three questions

Resect uses the word "classifier" for three unrelated components. They run
over the same symbol list and answer different questions.

### The comms classifier: "is this symbol part of a bus?"

`CommsClassifier` (`services/comms/comms_classifier.dart`) is the abstract
interface; the implementation both surfaces instantiate is
`NamePatternCommsClassifier` (same file). It tokenizes each
symbol name and assigns a [comms class](@ref gloss_comms_class) — `i2c`,
`spi`, `uart`, `unclassified` — plus a read/write role. Its output feeds
@ref comms_virtualization, which hooks a whole protocol coherently instead
of stubbing bus functions one at a time. Both surfaces run it through the
shared merge in `services/comms/comms_assignment_merge.dart` — the UI on
every graph load, the CLI at the start of `synthesize` and `autotune` —
with the project's existing assignments always winning over fresh
suggestions. Comms-assigned symbols are then
*excluded* from object grouping — the bus mechanism must not be split across
peripheral objects. (The template classifier below still runs over them, but
the comms pre-seed layer outranks any binding at run time, so its verdict on a
bus symbol never takes effect; see @ref hook_overlays.)

### The object-group classifier: "which symbols are one peripheral?"

`SymbolGroupClassifier` (`services/hooks/symbol_group_classifier.dart`)
recognizes [object groups](@ref gloss_object_group) — the member functions
of a peripheral "object" that must be hooked coherently or not at all. The
parse is **verb-anchored**: tokenize on `_` and camelCase, scan
left-to-right for the first role verb, and split there.

    LL_RCC_LSI_Enable              →  object LL_RCC_LSI          role enable
    LL_RADIO_TIMER_EnableTimer1    →  object LL_RADIO_TIMER_Timer1  role enable
    LL_RADIO_TIMER_IsEnabledTimer1 →  object LL_RADIO_TIMER_Timer1  role is-ready
    BLEPLAT_CNTR_PacketSetDataPtr  →  object BLEPLAT_CNTR_Packet  role set

The tokens before the verb are the object (and become the
[group scope](@ref gloss_group_scope)); the verb is the
[member role](@ref gloss_member_role); a digit-bearing token *after* the
verb is appended to the scope so `Timer1` and `Timer2` don't share state.
A symbol with no recognized verb is dropped rather than guessed at — which
is why a coincidental shared prefix never forms a group. Roles then pick
each member's hook: enable/set → write 1, disable/reset/clear → write 0,
is-ready/get → scoped read, init/deinit → return 0. Because the members
share one scope, the read a member does sees the write another member made.
@ref symbol_groups tells that story in full.

### The hook classifier: "which template fits this function's body?"

`HookClassifier` (`services/hooks/hook_classifier.dart`) is the
deterministic, no-LLM rule engine. Given a function's signature, its
decompiled body, and the firmware's data symbols, it returns either a
matched template *plus a runtime invariant*, or `null` meaning "no template
fits — this one needs an authored hook."

Seven rules, evaluated in this order (more specific first):

| Rule | Matches a body that is… | Template | Invariant checked afterwards |
|---|---|---|---|
| 1 empty-or-void-return | empty, or exactly `return;` | `return 0` | all returns == 0 |
| 2 return-literal | exactly `return <int literal>;` | `return <literal>` | all returns == that literal |
| 3 counter-global | `return <ident>;` where the ident is a data symbol named like a tick/counter | `increment` (scoped to the function) | strictly increasing; non-zero by call 2 |
| 4 chip-config-global | `return <ident>;` where the ident looks like a clock (`SystemCoreClock`, `HCLK`, `PCLK`, …) | `return 64000000` | constant, and inside 1–200 MHz |
| 5 busy-ready-flag | `return (… & mask …);` — a status-bit read | `return 0` for a *busy* name, `return 1` for ready/active/valid/present | returns ∈ {0,1} and equal to that value |
| 7 hal-polling-loop | a `do { … } while` containing `HAL_GetTick()`, returning a `*Status*` type | `return 0` (HAL_OK) | all returns == 0, never 1/2/3 |
| 6 pure-peripheral-writes | only register/struct-field assignments, `void` return | `return 0` | all returns == 0 |

Two design points are easy to miss. First, the **invariant** is not
decoration: it's a post-execution check the hook scorer evaluates against
ten captured return values from the bundled test rig, so a template that
matched syntactically but behaves wrongly (the classic `HAL_GetTick`
hooked to a constant 0) gate-fails instead of shipping. Second, **"no
template fits" is defined as the complement of all seven rules** — when
every rule misses, the caller falls through to the LLM authoring path.
That fall-through is the only such path, by construction.

Rule 4's 64 MHz is the STM32WB05 typical core clock, hardcoded for now;
deriving it from the chip ID or the `.repl` is open work.

## Step 5 — Binding: classification becomes candidates

A classification is knowledge; a [binding](@ref gloss_binding) is the
per-project record of that knowledge, and bindings are what the
synthesizer ranks. `HookBindingSeeder.seedBindingsForElf`
(`services/hooks/hook_binding_seeder.dart`) walks every function that has
both a signature and a non-empty decompilation, classifies it, and emits
one binding per match:

- **Find-or-create the artifact.** If the template's body already exists
  as a row (usually one of the eight defaults), the binding reuses that id;
  otherwise a new `origin='user'` row is inserted with the target symbol
  recorded.
- **[Fidelity](@ref gloss_fidelity) by rule.** Rules 1 and 2 score
  **0.25** — they matched, but the chosen body is a generic template and
  the match could be coincidental. Rules 3–7 score **0.5** — a specialized
  pattern that isn't coincidence-matchable.
- **[Provenance](@ref gloss_provenance) records which rule fired**
  (`classifier:rule-5-busy-ready-flag`). That string is load-bearing far
  downstream: @ref autotune_decisions turns it into the human-readable
  annotation the LLM reads ("ready/busy flag", "clock getter", "void
  register writes").
- **The template's [scope](@ref gloss_scope) travels onto the binding**, so
  a stateful hook redeploys into the same Renode Python-globals namespace
  the template expected.

Per the [bodies-vs-associations rule](@ref bodies_vs_associations), the
bodies land in the database and the bindings land in the `.emu` — the
seeder returns a map for the caller to merge, and never writes the project
itself.

@note **Deviation from the current code.**
**Today:** `HookBindingSeeder` is called from exactly one place —
`_seedClassifierBindings` in
`emulator_ui/lib/presentation/screens/library/library_actions.dart`, on
project open. The [CLI](@ref cli) never runs it, and the
[container](@ref containers) images ship no Ghidra and no `GHIDRA_DIR`,
so a headless session has no decompilations, no classifier bindings, and
no `classifier:*` annotations in its LLM prompts.
**Planned:** the seeding pass belongs behind @ref controller_projects
(@ref phase_p5), driven identically from both surfaces, with Ghidra
availability in the container path resolved alongside it.
**Why:** the headless loop is the one that runs unattended for dozens of
rounds, and it is currently the one reasoning with the least information —
the reverse of what you want.

## Step 6 — How candidates get ranked at run time

The per-symbol candidate list is assembled inside the synthesizer, the
first time the firmware faults at that symbol
(`synthesizer_workflow.dart`). Three things decide the order:

1. **The candidate pool is the whole artifact database.**
   `getArtifactsForSymbolByName(elfHash, symbol)` currently ignores both
   arguments and returns `getAllArtifacts()`. Every symbol's list is every
   hook body Resect knows about.
2. **Effective score, descending**, then origin, then id:

       COALESCE(binding.fidelity, artifact.intrinsicScore, 0.0) DESC, origin ASC, id ASC

   A binding's fidelity *replaces* the artifact's intrinsic floor for that
   symbol. So a classifier binding at 0.5 outranks a bare `return 0` at
   0.0, and an LLM-authored replacement seeded at 0.5 sorts to the front on
   the retry immediately after it's written.
3. **A [preference](@ref gloss_preference) jumps the queue** — if the
   project names a preferred artifact for the symbol, it moves to index 0
   on top of the score sort.

Then one threshold governs when the machine stops guessing and asks for
help: `_kLlmEngageMinScore = 0.5`. As soon as no *specialized* candidate
(score ≥ 0.5 — a classifier binding or a user-authored replacement)
remains untried for a symbol, the synthesizer invokes the
[LLM fallback](@ref gloss_llm_fallback) rather than grinding through
generics. This matters because the candidate list is the whole database —
waiting for literal exhaustion meant a hard symbol burned the
whole iteration budget before the LLM was ever asked. Generics remain in
the list as a last resort *after* the LLM attempt.

## What synthesis actually receives

By the time `SynthesizerWorkflow.run` is called, the pre-synthesis stage
has produced exactly this:

| Input | From | Role in the run |
|---|---|---|
| `elfPath`, `baseImagePath` | The project | What to load into Renode |
| `elfHash` | Step 1 | The key for every candidate lookup |
| `hookOverrides` + scopes | You, or an accepted [recommendation](@ref gloss_recommendation) | Pre-seeded first; a failure here fails the run |
| `commsHooks` | Step 4 (comms) | Pre-seeded second, per-protocol scope |
| `resolvedHooks` | The last successful run | [Warm start](@ref gloss_warm_start), pre-seeded third |
| `symbolGroups` + `groupOverrides` | Step 4 (groups) | Forced groups pre-seeded; the rest escalate on first member fault |
| `hookBindings` | Step 5 | The scored knowledge candidate ranking uses |
| `hookPreferences` | You | The soft queue-jump |
| `maxIterations` | CLI / config (500 headless) | The iteration [stopping condition](@ref gloss_termination_reason) |
| `llmGenerator` | The LLM stack | The fallback author |

Which is the same list @ref hook_overlays describes from the overlay side,
and the input side of @ref synthesis.

## In short

Hash the ELF and register its symbols; extract the call graph with objdump
(direct calls only — remember that); optionally run Ghidra to get
signatures, decompiled bodies, and data symbols. Then classify three ways:
comms class per symbol, object groups by verb-anchored name parse, and
template-vs-author per function body via seven deterministic rules. Turn
the matches into bindings scored 0.25 or 0.5 with the rule recorded as
provenance. At run time a symbol's candidates are the whole artifact
database sorted by binding fidelity (else intrinsic score), with
preferences jumping the queue and the LLM engaged the moment nothing
specialized is left. Without Ghidra, step 4's third classifier does
nothing — and that's the state every headless run is in today.
