# Getting Started {#getting_started}

This page gets you from a fresh clone to your first
[synthesis](@ref gloss_synthesis) run. It assumes Ubuntu/Pop!_OS Linux and
nothing else.

## Install

From the repository root:

    ./install.sh

The installer installs everything it needs — you should not need to
install anything by hand. It:

1. installs the system packages (build toolchain, GTK dev headers,
   `binutils-arm-none-eabi` for objdump-based
   [call-graph](@ref gloss_call_graph) extraction, git-lfs),
2. finds or installs the Flutter SDK (git clone, Linux desktop only),
3. fetches the engine assets — the portable [Renode](@ref gloss_renode)
   binary — via Git LFS into `emulation_engine/`,
4. resolves the Dart workspace (`dart pub get`), and
5. seeds `resect.config`, the key=value file shared by the app and the
   shell scripts.

One optional flag: `./install.sh --with-vagrant-test` also installs
VirtualBox + Vagrant for the CI test harness (~250 MB — skip it unless you
need the "Run Vagrant Test" feature).

Two features are installed *from inside the app* instead, via
**Tools ▸ System Configuration**: the local LLM runtime (Ollama, used by
everything with "LLM" in the name) and Ghidra (used by
[Ghidra extraction](@ref gloss_ghidra_extraction)). Resect works without
them — you just lose LLM assistance and signature-aware features until
they're enabled.

## Run

    ./run.sh

This regenerates database code if needed (pass `--regen` to force it after
schema changes), then launches the desktop app. On first run a setup wizard
(the System Configuration dialog) walks you through module setup.

## Your first project, in five minutes

1. **Library tab → Create.** Name the [project](@ref gloss_project) and
   pick two files: your firmware ELF and a Renode `.repl` platform
   description for the board.
2. **Call Graph tab.** The [call graph](@ref gloss_call_graph) is extracted
   and drawn. Click nodes; this is your map of the firmware.
3. **Synthesize tab → Run Synthesis.** Watch the console: the firmware
   runs, faults on unmodeled hardware, gets a [hook](@ref gloss_hook),
   and runs again — @ref synthesis explains each iteration.
4. When it finishes, the report shows [fidelity](@ref gloss_fidelity)
   scores and per-symbol decisions. Save the project (Ctrl+S / Library
   tab): your resolved hooks become the [warm start](@ref gloss_warm_start)
   for next time.

From there, the interesting work begins: review hook choices in the Call
Graph tab's metadata panel (@ref hook_overlays), virtualize bus traffic in
the Comms tab (@ref comms_virtualization), or let the LLM tune the setup
over several rounds with the Auto-tune button (@ref autotune).

## Prefer a terminal?

Everything above has a headless equivalent:

    dart run emulator_orchestrator:cli --help

See @ref cli for the command tour.

## In short

`./install.sh`, then `./run.sh`, then Library → Create → Synthesize. Ollama
and Ghidra install from inside the app when you want the LLM- and
signature-powered features.
