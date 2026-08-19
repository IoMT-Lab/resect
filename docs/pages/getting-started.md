# Getting Started {#getting_started}

This page gets you from a fresh clone to your first
[synthesis](@ref gloss_synthesis) run. There are two paths, and they are not
equivalent:

- **The container path** — `docker compose` brings up
  [Renode](@ref gloss_renode), Ollama, the models, and Resect. Nothing to
  install but Docker, and it is what most people running Resect will use.
  Start here.
- **The host path** — `./install.sh` builds and runs the Flutter app
  natively. This is the development setup, and the only way to work on the
  UI.

## The container path

Requirements: Docker with the Compose plugin, and enough disk for the
images plus a few GB of model weights.

    git clone <this repo> && cd resect
    ./scripts/install.sh     # once: pulls the LLM models into a persistent volume
    ./scripts/run_cli.sh

`install.sh` is the slow step (several GB of model weights: `gemma4:e4b` +
`nomic-embed-text`); it is idempotent, and nothing LLM-flavored works until
it has run once. `run_cli.sh` then lands you in a shell in `/workdir` — a
bind mount of `./workdir` on the host — with the CLI on your `PATH`:

    resect-cli create --name aya --elf example/aya_ppg.elf \
        --repl example/stm32wb05_empty.repl -o example/aya.emu
    resect-cli synthesize --elf example/aya_ppg.elf \
        --repl example/stm32wb05_empty.repl --save-emulator example/aya.emu
    resect-cli autotune --emu example/aya.emu --max-rounds 10

Put your firmware ELF and its Renode `.repl` platform file under `./workdir`
first; everything the run writes — the project, [manifests](@ref gloss_manifest),
auto-tune reports — appears back on the host, owned by you.

For the desktop app in a container there are two modes:
`./scripts/run_gui.sh` opens it on your own display (native Wayland/X11
passthrough), and `./scripts/run_vnc.sh` serves it on a virtual display —
connect a VNC client to `localhost:5900`. Full detail, including what the
image deliberately doesn't contain, is @ref containers.

## The host path

Ubuntu/Pop!_OS assumed. From the repository root:

    ./install.sh

The installer installs everything it needs — you should not need to install
anything by hand. It:

1. installs the system packages (build toolchain, GTK dev headers,
   `binutils-arm-none-eabi` for objdump-based
   [call-graph](@ref gloss_call_graph) extraction, git-lfs),
2. finds or installs the Flutter SDK (git clone, Linux desktop only),
3. resolves the Dart workspace (`dart pub get` — the engine packages come
   from the hosted package repository; see @ref workspace_layout), and
4. seeds `resect.config`, the key=value file shared by the app and the shell
   scripts.

One optional flag: `./install.sh --with-vagrant-test` also installs
VirtualBox + Vagrant for the CI test harness (~250 MB — skip it unless you
need the "Run Vagrant Test" feature).

Then launch the app:

    ./run.sh

(`--regen` forces Drift code generation after a database schema change.) On
first run a setup wizard — the System Configuration dialog — walks you
through module setup.

Three things the installer does **not** do, because they're deliberate
choices:

- **A Renode server.** Resect's [engine](@ref gloss_engine) *connects* to
  Renode in server mode at `RENODE_HOST:RENODE_PORT`; it does not launch
  one. Point those keys at the `renode` container from the compose stack, or
  at a portable Renode you started yourself
  (`renode -p --disable-gui --server-mode --server-mode-port 5000`). Note
  that scoped hooks need the **patched** portable build this project pins —
  see @ref workspace_layout.
- **Ollama**, for everything with "LLM" in the name.
- **Ghidra**, for [Ghidra extraction](@ref gloss_ghidra_extraction) — which
  is what gives the [classifier](@ref gloss_classifier) and the LLM prompts
  real function bodies to read (@ref pre_synthesis).

The last two install *from inside the app*, via **Tools ▸ System
Configuration**. Resect works without them — you just lose LLM assistance
and every signature-aware feature until they're enabled.

## Your first project, in five minutes (UI)

1. **Library tab → Create.** Name the [project](@ref gloss_project) and pick
   two files: your firmware ELF and a Renode `.repl` platform description
   for the board.
2. **Call Graph tab.** The [call graph](@ref gloss_call_graph) is extracted
   and drawn. Click nodes; this is your map of the firmware.
3. **Synthesize tab → Run Synthesis.** Watch the console: the firmware runs,
   faults on unmodeled hardware, gets a [hook](@ref gloss_hook), and runs
   again — @ref synthesis explains each iteration.
4. When it finishes, the report shows [fidelity](@ref gloss_fidelity) scores
   and per-symbol decisions. Save the project (Ctrl+S / Library tab): your
   resolved hooks become the [warm start](@ref gloss_warm_start) for next
   time.

From there, the interesting work begins: review hook choices in the Call
Graph tab's metadata panel (@ref hook_overlays), virtualize bus traffic in
the Comms tab (@ref comms_virtualization), or let the LLM tune the setup over
several rounds with the Auto-tune button (@ref autotune).

## In short

`./scripts/run_cli.sh` for the containerized stack — the canonical path, and
the one to verify changes against. `./install.sh` + `./run.sh` for native
development, remembering that Renode, Ollama, and Ghidra are yours to
provide. Either way the first project is Create → Call Graph → Synthesize.
