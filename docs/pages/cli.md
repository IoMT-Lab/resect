# The Command Line {#cli}

Everything the UI does rests on plain-Dart code in `emulator_orchestrator`,
so all of it can run headlessly. The CLI
(`emulator_orchestrator/bin/cli.dart`) is both a practical tool and an
architectural proof: if a feature can't be driven from here, its logic is
trapped in the UI (see @ref architecture).

Two ways to invoke it, same binary logic:

    resect-cli <command> [options]                      # inside the container
    dart run emulator_orchestrator:cli <command> [...]  # on the host

The container form is the canonical one (@ref containers); the host form
needs a resolved Dart workspace. Run any command with `--help` for its full
flag list.

## The commands

**`create`** — make a new [project](@ref gloss_project) file.

    resect-cli create --name aya --elf firmware.elf --repl board.repl -o aya.emu

**`callgraph`** — extract a [call graph](@ref gloss_call_graph) from an ELF
and print it (`--format json|summary`). Also registers the firmware in the
[artifact database](@ref gloss_artifact_db) as a side effect.

**`synthesize`** — run a single @ref synthesis pass against firmware.

    resect-cli synthesize --elf firmware.elf --repl board.repl \
        --start-from main --end-at loop_forever \
        --save-emulator aya.emu

Prints the result (with [fidelity](@ref gloss_fidelity) metrics) as JSON.
Bus functions are classified up front exactly the way the UI does it
(@ref comms_virtualization), and `--comms <csv|none>` picks which protocols
to virtualize as a unit (default `i2c,uart,spi`). `--save-emulator`
persists the resolved hooks, the comms assignments, and the call graph as a
project you can open in the UI — or feed straight to `autotune`.
`--max-iterations` caps the loop (default 500).

**`autotune`** — run a full @ref autotune session against a saved project,
auto-accepting every [recommendation](@ref gloss_recommendation) (the
accept-all [review policy](@ref gloss_review_policy)).

    resect-cli autotune --emu aya.emu --max-rounds 10 --comms i2c,uart

The call graph a `.emu` carries is stamped with the SHA-256 of its source
ELF (`elfHash`). On start, `autotune --emu` validates that stamp against
the firmware actually being emulated; on mismatch it logs the rejection to
stderr and re-extracts the graph
(`services/analysis/call_graph_guard.dart`), so the LLM never reasons over
another firmware's symbols. Unstamped graphs from older `.emu` files can't
be validated, so they regenerate once — the fresh graph comes back stamped.

Writes per-[round](@ref gloss_round) reports and a `summary.md` (locations in
@ref storage_map; how to read them in @ref autotune_decisions). The flags
that change behavior rather than paths:

| Flag | Default | Effect |
|---|---|---|
| `--max-rounds <n>` | 5 | LLM rounds after the baseline |
| `--max-iterations <n>` | 500 | Synthesizer iteration cap per round |
| `--max-recs <n>` | 10 | Recommendations the model may emit per round (the schema's `maxItems`) |
| `--stagnant-limit <n>` | 2 | Consecutive stagnant rounds before stopping with `noCoverageProgress` |
| `--comms <csv\|none>` | `i2c,uart,spi` | Protocols to virtualize as a unit (@ref comms_virtualization) |
| `--save-comms` | off | Persist the merged comms assignments back into the `.emu`. By default classification is in-memory and the file is never written |
| `--warm-start` | off | Seed each round with the previous round's resolved hooks. Default (cold start): every round re-synthesizes from the overlay set — independent, comparable rounds |
| `--model <tag>` / `--host <h:p>` | `resect.config` | Ollama overrides |
| `--start-from` / `--end-at` | the project's | Override the run's entry and stop symbols |
| `--report-dir <path>` | `<projectDir>/autotune_reports/<timestamp>/` | Where reports land |
| `--color <auto\|always\|never>` | `auto` | Colorize the console output |

**`fidelity`** — compute fidelity metrics for a call graph (`--elf` or a
saved `--callgraph` JSON), with `--hooks`, `--traversed`,
`--start-from`/`--end-at` to describe the scenario. Handy for scripting
comparisons without running an emulation.

**`export`** — turn a project into a standalone Renode `.resc` script:

    resect-cli export --emulator aya.emu -o aya.resc

## Global options

`--backend-url <url>` still appears in the usage strings, but no command
reads it — it is vestigial. `--engine-dir <path>` still exists and is still
accepted, but the emulation path no longer uses it: Resect connects to a
**Renode server**
at `RENODE_HOST:RENODE_PORT` from `resect.config` (@ref orchestrator_engine).
The engine directory only matters to the Vagrant export and the hook-quality
harness, which do launch a portable Renode themselves.

## What the headless path does *not* have

The CLI wires the LLM stack unconditionally — the recommender and the hook
generator are always constructed — so @ref autotune works headlessly. But
the CLI never runs the [classifier](@ref gloss_classifier) binding-seed pass
(it lives in the UI's project-open path), and the container images ship no
Ghidra. So a headless session has no decompiled function bodies to reason
from: no classifier [bindings](@ref gloss_binding), no frontier annotations,
no decompilation in [RAG](@ref gloss_rag) retrieval. See the deviation note
in @ref pre_synthesis — it is the biggest current difference between the two
surfaces.

## The headless API server

For programmatic use beyond the CLI there is also an HTTP server
(`dart run emulator_orchestrator:server`) exposing project create/list (no
update or delete), call graphs, synthesizer runs (with server-sent events),
emulation start/stop, and fidelity — same orchestrator underneath.

## A typical headless loop

    # 1. Create the project once
    resect-cli create --name dev1 --elf fw.elf --repl board.repl -o dev1.emu

    # 2. Baseline synthesis, saving resolved hooks back into it
    resect-cli synthesize --elf fw.elf --repl board.repl --save-emulator dev1.emu

    # 3. Let the LLM tune it overnight; read summary.md in the morning
    resect-cli autotune --emu dev1.emu --max-rounds 10

The `.emu` written here opens in the UI afterwards — same
[model](@ref gloss_model), same [controllers](@ref gloss_controller).

@note **Deviation from the current code.**
**Today:** the CLI edits the `Emulator` object's fields directly in
`bin/cli.dart` rather than calling controller methods, because the
ProjectController does not exist yet.
**Planned:** @ref phase_p5 converts these direct mutations to the same
`ProjectController` calls the UI makes.
**Why:** direct field edits skip dirty tracking and change events, so
CLI-side project handling has to re-implement what the UI already does — the
exact duplication the architecture removes.

## In short

Six commands — `create`, `callgraph`, `synthesize`, `autotune`, `fidelity`,
`export` — driving the same objects as the UI, as `resect-cli` in the
container or `dart run` on the host. Renode is reached over the network, not
launched, so `--engine-dir` is vestigial on the emulation path. If you can't
do something from here, that's an architecture bug worth filing.
