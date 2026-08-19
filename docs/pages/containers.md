# Running in Containers {#containers}

The containerized stack is Resect's canonical way to build and run: one
`compose.yml` at the repository root brings up [Renode](@ref gloss_renode),
Ollama, and Resect itself, with no host setup beyond Docker. It is also
what everyone who *uses* Resect without developing it will run, which makes
it the right place to verify a change. This page is the map of that stack.

If you are developing on the host instead, see @ref getting_started — the
same code, wired to host-local paths.

## The stack

    compose.yml  (+ .env for display/env-file defaults)
    ├── profile: normal                 ├── profile: init
    │   ├── resect   (one image; runs   │   ├── ollama       (shared with normal)
    │   │             as cli, gui,      │   └── ollama-init  (one-shot model pull)
    │   │             or vnc mode)      │
    │   ├── renode   (Renode server)    └── profile: _  (never auto-started)
    │   └── ollama   (healthchecked)        └── cache-cleaner (wipes resect-state)

    networks: default bridge
    volumes:  resect-state (app data)   ollama-models (LLM weights)

| Service | Image | Job |
|---|---|---|
| `resect` | `nexus.medmakers.io/docker/resect` | **One image carrying both surfaces**: the [CLI](@ref cli) as `resect-cli` and the Flutter app as `resect`. The entrypoint's mode argument (`cli` / `gui` / `vnc`) picks which runs. |
| `renode` | `nexus.medmakers.io/docker/renode` | The Renode **server** the Resect container connects to. |
| `ollama` | `ollama/ollama` | Inference + embeddings over HTTP, healthchecked before Resect starts. |
| `ollama-init` | `ollama/ollama` | Pulls `gemma4:e4b` (override with `RESECT_LLM_MODEL`) and `nomic-embed-text`, then exits. **`init` profile — runs only via `install.sh`.** |
| `cache-cleaner` | `busybox` | Deletes the contents of the `resect-state` volume. Only reachable via `clean.sh`. |

Startup order within `normal` is enforced by conditions, not sleeps:
Resect waits for `renode` to have started and `ollama` to report
**healthy**. Note what is *no longer* in that chain: the model pull.
`ollama-init` lives in its own `init` profile, so a fresh clone that goes
straight to `run_cli.sh` gets an Ollama with **no models** — every
LLM-touching feature fails until `./scripts/install.sh` has run once. The
pull is idempotent; re-running `install.sh` on a warm volume returns
immediately.

## The scripts

`scripts/` wraps the compose invocations. Each one works from the repo
root or from inside `scripts/`:

    ./scripts/install.sh    # FIRST RUN: creates ./workdir, pulls the LLM models
    ./scripts/build.sh      # docker compose build resect (local image build)
    ./scripts/run_cli.sh    # interactive CLI shell in /workdir
    ./scripts/run_gui.sh    # the GUI on YOUR display (native Wayland/X11 passthrough)
    ./scripts/run_vnc.sh    # the GUI on a virtual display, VNC on :5900
    ./scripts/stop.sh       # stop both profiles, keep volumes
    ./scripts/clean.sh      # WIPES the resect-state volume's contents (app data)
    ./scripts/uninstall.sh  # down -v --remove-orphans — DESTROYS both volumes

Two of these are destructive and easy to confuse: `clean.sh` empties the
app-state volume (your [artifact database](@ref gloss_artifact_db),
projects) but keeps the volumes and the model cache; `uninstall.sh`
removes the volumes entirely, models included. Use `stop.sh` unless you
mean to lose state.

The run scripts pass your identity through:

    docker compose --profile normal run --rm \
        -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) resect cli

That matters — see [file ownership](@ref containers_ownership) below.

## One image, three modes

The entrypoint (`docker/entrypoint.sh`) takes a mode argument — the last
word on each run script's compose line — and validates it:

- **`cli`** (the default `CMD`) — drops you into a bash shell as the host
  user with `resect-cli` on the `PATH`.
- **`gui`** — launches the Flutter app on *your* display. The compose file
  mounts your Wayland socket and the X11 socket into the container, and
  `run_gui.sh` swaps in `docker/gui.env` (via the `INTERNAL_ENV_FILE`
  variable defaulted in `.env`), which carries the display plumbing:
  Wayland-first toolkit fallbacks, software rendering, and the D-Bus /
  at-spi workarounds a containerized GTK app needs.
- **`vnc`** — launches the app on a virtual display instead: `Xvfb` at
  1920×1080, `x11vnc` on port 5900 (**no password**, shared). Connect any
  VNC client to `localhost:5900`. `run_vnc.sh` passes `--service-ports`
  so the port mapping applies; the other modes never publish it.

Because the VNC server is unauthenticated, treat the published port as
local-only; change the compose mapping to `127.0.0.1:5900:5900` if the
host is not private.

## A CLI session

    $ ./scripts/install.sh      # once — model pull into the ollama-models volume
    $ ./scripts/run_cli.sh
    Starting container as user: evan (UID: 1000, GID: 1000)
    Resect CLI available as 'resect-cli'

    # inside the container, in /workdir (a bind mount of ./workdir)
    $ resect-cli create --name aya --elf example/aya_ppg.elf \
          --repl example/stm32wb05_empty.repl -o example/aya.emu
    $ resect-cli autotune --emu example/aya.emu --max-rounds 10

Put firmware in `./workdir` on the host and it appears under `/workdir`;
[reports and manifests](@ref storage_map) the run writes there appear back
on the host, owned by you. (`workdir/` is gitignored apart from the
shipped example files, so run artifacts no longer clutter `git status`.)
To run one command and exit instead of getting a shell, append it after
the mode:

    docker compose --profile normal run --rm \
        -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
        resect cli    # then run resect-cli ... in the shell it opens

## Configuration inside the container

The image ships one `resect.config` (`docker/resect.config`) at
`/resect.config`, pointed to by the `RESECT_CONFIG` environment variable:

    ARM_OBJDUMP="/usr/bin/arm-none-eabi-objdump"
    X86_OBJDUMP="/usr/bin/objdump"
    LLM_OLLAMA_HOST="ollama:11434"
    LLM_MODEL=""
    RENODE_HOST="renode"
    RENODE_PORT="5678"
    SETUP_DONE="1"

Read that list as a statement of what the container path *is*:

- **Renode is remote.** `RENODE_HOST`/`RENODE_PORT` name the `renode`
  service. Resect's [engine](@ref gloss_engine) connects to a Renode
  server; it does not launch one (see @ref orchestrator_engine), so
  `--engine-dir` has no effect here.
- **Ollama is remote**, reached by service name over the compose network.
  `LLM_MODEL` is empty, so the CLI falls back to its own default,
  `gemma4:e4b` — the model `install.sh` pulls. Override per invocation
  with `--model` / `--host`.
- **objdump is present**, so [call-graph](@ref gloss_call_graph) extraction
  works (`binutils-arm-none-eabi` is installed in the runtime image).
- **`SETUP_DONE=1`** suppresses the first-run setup wizard in the GUI.
- **There is no Ghidra**, no `GHIDRA_DIR`, and no `MODULE_GHIDRA`. So no
  signatures, no decompiled bodies, no `HookClassifier` bindings, no
  decompilation in [RAG](@ref gloss_rag) retrieval — the annotation layer
  described in @ref pre_synthesis is absent, and with it the frontier
  annotations @ref autotune_decisions relies on. The LLM stack itself is
  *not* gated: the CLI wires the recommender and the hook generator
  unconditionally, so auto-tune runs — it just reasons from names rather
  than from bodies.

## Where container state lives {#containers_state}

`resect-state` is mounted at `/static_home`, and the entrypoint symlinks
the container user's `$HOME/.config` to it. Since Resect keeps everything
under `~/.config/call_graph_viewer` (`core/app_paths.dart`), the effect is:

| Inside the container | Actually |
|---|---|
| `~/.config/call_graph_viewer/artifact_library/artifacts.db` | `resect-state` volume |
| `~/.config/call_graph_viewer/projects/` | `resect-state` volume |
| `/workdir` (working dir) | `./workdir` on the host |

So the artifact database persists across container runs and across the
three modes (they are one image sharing one volume), while everything you
want to *read* — projects, reports, manifests — should live under
`/workdir` where the host can see it. `clean.sh` is the sanctioned way to
reset the state volume without touching the model cache. Full inventory in
@ref storage_map.

## File ownership {#containers_ownership}

The entrypoint runs the same steps in every mode before starting anything:

1. Create a group and user matching `HOST_GID`/`HOST_UID` (default 1000).
2. Point that user's `$HOME/.config` at `/static_home` and `chown` both.
3. `exec gosu <user> …` — the app runs as you, never as root.

That is why the run scripts pass `-e HOST_UID=$(id -u) -e HOST_GID=$(id -g)`.
Skip it on a host where your UID isn't 1000 and every file the run writes
into `./workdir` lands owned by the wrong user.

## Building vs pulling

The `resect` service names both an `image:` and a `build:`, so
`./scripts/build.sh` (`docker compose build resect`) rebuilds locally and a
plain `run` pulls the published image. Pull unless you are testing
unpublished code — and say which one you did when reporting a result.

`docker/Dockerfile` is a two-stage build from the shared
`nexus.medmakers.io/docker/flutter` builder image, and it now builds
**both surfaces into one runtime**: `flutter pub get`, Drift codegen
(`build_runner`), `dart build cli` → `/bin/resect-cli`, and
`flutter build linux` → `/bin/resect`, layered onto `ubuntu:24.04` with
objdump, SQLite, GTK, the Wayland/X11 client libraries, and the
Xvfb/x11vnc pieces for VNC mode.

A local build resolves dependencies from `pubspec.lock`, so the engine
packages come from the hosted repository — a local
`pubspec_overrides.yaml` on your host does **not** affect the image (see
@ref workspace_layout).

## Troubleshooting

**The Docker daemon won't start** (`iptables ... nf_tables` failures in
`journalctl -u docker`). On distributions where `iptables` defaults to the
nftables backend, switch the alternative and restart:

    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
    sudo systemctl restart docker

**LLM calls fail / model not found.** You skipped `./scripts/install.sh`.
The model pull is no longer part of normal startup — run it once, watch it
with `docker compose --profile init logs -f ollama-init` if it seems stuck
(it is pulling several GB).

**`resect-cli` can't reach Renode.** Both are in the `normal` profile;
check `docker compose ps` shows the `renode` service running and that
`RENODE_HOST` in `/resect.config` says `renode`.

**The native GUI won't open.** `run_gui.sh` requires a Wayland session
(it mounts `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`; `.env` defaults these for
UID-1000 sessions). On X11-only hosts or over SSH, use `run_vnc.sh`
instead — that path needs nothing from the host display.

**Port 5900 is busy.** Only `run_vnc.sh` publishes it
(`--service-ports`); another VNC server is holding it, or a previous vnc
container is still up (`./scripts/stop.sh`).

**Files in `./workdir` are owned by root.** The run didn't get
`HOST_UID`/`HOST_GID`; use the scripts, or pass them explicitly.

## In short

One compose file, one Resect image with three modes. `install.sh` once to
pull the models; then `run_cli.sh` for a shell, `run_gui.sh` for the app
on your own display, `run_vnc.sh` for a virtual display on :5900. The
`normal` profile pairs Resect with its Renode server and a healthchecked
Ollama; app state lives in the `resect-state` volume via `$HOME/.config`
→ `/static_home`, work you want to read lives in the `./workdir` bind
mount, `clean.sh` wipes state, `uninstall.sh` wipes everything. Renode and
Ollama are reached over the network, objdump is present, and Ghidra is
not — so headless sessions run without the decompilation-derived
annotations.
