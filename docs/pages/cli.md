# The Command Line {#cli}

Everything the UI does rests on plain-Dart code in
`emulator_orchestrator`, so all of it can run headlessly. The CLI
(`emulator_orchestrator/bin/cli.dart`) is both a practical tool and an
architectural proof: if a feature can't be driven from here, its logic is
trapped in the UI (see @ref architecture).

Run any command with `--help` for its full flag list. The entry point:

    dart run emulator_orchestrator:cli <command> [options]

## The commands

**`create`** — make a new [project](@ref gloss_project) file.

    dart run emulator_orchestrator:cli create \
        --name aya-ppg --elf firmware.elf --repl board.repl -o aya-ppg.emu

**`callgraph`** — extract a [call graph](@ref gloss_call_graph) from an ELF
and print it (`--format json|summary`). Also registers the firmware in the
[artifact database](@ref gloss_artifact_db) as a side effect.

**`synthesize`** — run a single @ref synthesis pass against firmware.

    dart run emulator_orchestrator:cli synthesize \
        --elf firmware.elf --repl board.repl \
        --start-from main --end-at loop_forever \
        --save-emulator aya-ppg.emu

Prints the result (with [fidelity](@ref gloss_fidelity) metrics) as JSON;
`--save-emulator` persists the resolved hooks as a project you can open in
the UI.

**`autotune`** — run a full @ref autotune session against a saved project,
auto-accepting every [recommendation](@ref gloss_recommendation) (the
accept-all [review policy](@ref gloss_review_policy)).

    dart run emulator_orchestrator:cli autotune --emu aya-ppg.emu \
        --max-rounds 6 --comms i2c,uart

Writes per-[round](@ref gloss_round) reports and a `summary.md` (locations
in @ref storage_map). Useful flags: `--max-rounds`, `--max-recs`,
`--stagnant-limit`, `--comms <csv|none>` (which protocols to virtualize,
default `i2c,uart,spi`), `--model`/`--host` (Ollama overrides),
`--report-dir`.

**`fidelity`** — compute fidelity metrics for a call graph (`--elf` or a
saved `--callgraph` JSON), with `--hooks`, `--traversed`,
`--start-from`/`--end-at` to describe the scenario. Handy for scripting
comparisons without running an emulation.

**`export`** — turn a project into a standalone Renode `.resc` script:

    dart run emulator_orchestrator:cli export --emulator aya-ppg.emu -o aya.resc

## Global options

Every engine-touching command accepts `--engine-dir <path>` (where the
portable [Renode](@ref gloss_renode) lives; defaults come from
`resect.config`) and `--backend-url <url>` to attach to an
already-running engine instead of starting one.

## The headless API server

For programmatic use beyond the CLI there is also an HTTP server
(`dart run emulator_orchestrator:server`) exposing project CRUD, call
graphs, synthesizer runs (with server-sent events), and fidelity — same
orchestrator underneath.

## A typical headless loop

    # 1. Create the project once
    dart run emulator_orchestrator:cli create --name dev1 \
        --elf fw.elf --repl board.repl -o dev1.emu

    # 2. Baseline synthesis, saving resolved hooks back into it
    dart run emulator_orchestrator:cli synthesize --elf fw.elf \
        --repl board.repl --save-emulator dev1.emu

    # 3. Let the LLM tune it overnight; read summary.md in the morning
    dart run emulator_orchestrator:cli autotune --emu dev1.emu --max-rounds 10

The `.emu` written here opens in the UI afterwards — same
[model](@ref gloss_model), same [controllers](@ref gloss_controller).

@note **Deviation from the current code.**
**Today:** the CLI edits the `Emulator` object's fields directly in
`bin/cli.dart` rather than calling controller methods, because the
ProjectController does not exist yet.
**Planned:** @ref phase_p5 converts these direct mutations to the same
`ProjectController` calls the UI makes.
**Why:** direct field edits skip dirty tracking and change events, so
CLI-side project handling has to re-implement what the UI already does —
the exact duplication the architecture removes.

## In short

Six commands — `create`, `callgraph`, `synthesize`, `autotune`,
`fidelity`, `export` — driving the same objects as the UI. If you can't do
it from here, that's an architecture bug worth filing.
