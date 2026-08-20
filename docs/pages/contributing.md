# Contributing {#contributing}

How to set up a dev environment, run the tests, and keep the codebase (and
these docs) in the shape the @ref architecture describes.

## Dev setup

1. Clone this repo and run `./install.sh` (see @ref getting_started).
2. The engine packages resolve from the hosted package repository, so no
   sibling checkouts are needed to build. To co-develop one, add a
   git-ignored `pubspec_overrides.yaml` pointing at your local checkout —
   and remember that shipping the change needs a **version bump**, because
   the hosted repository serves immutable versions. @ref workspace_layout has
   the details.
3. Emulation needs a reachable Renode **server** (`RENODE_HOST`/`RENODE_PORT`
   in `resect.config`) — the container stack provides one; otherwise start a
   patched portable build in server mode yourself. LLM features need Ollama;
   signature features need Ghidra. The latter two install from
   **Tools ▸ System Configuration** inside the app.

## Running things

    ./run.sh                 # the desktop app (add --regen after DB schema edits)
    dart run emulator_orchestrator:cli --help    # headless, on the host
    ./scripts/run_cli.sh                         # headless, in the container

The CLI commands have their own page: @ref cli; the container stack is
@ref containers.

## Tests

    cd emulator_orchestrator && dart test        # logic, models, engine
    cd emulator_ui && flutter test               # widgets, UI loops

Slower, environment-dependent checks (live Ollama, Ghidra, Renode) live as
scripts in `emulator_orchestrator/tool/` rather than in `test/` — run the
relevant one when you touch its subsystem.

One rule: **a clean analyzer is not a passing test, and a passing test is
not a working feature.** Before calling a change done, run the
concrete thing — the CLI command, the UI flow, the tool script — and watch
it do what you claimed. For anything touching the loops, run it the way
users will: through the container stack, and say which image you used
(pulled or locally built).

## Code conventions

- **Respect the dependency direction.** `emulator_ui` may import
  `emulator_orchestrator`; never the reverse. Anything in
  `emulator_orchestrator/lib/data/models/` stays Flutter-free *and*
  service-free (pure data).
- **Widgets render; controllers act.** If a widget grows a multi-step
  workflow (generate → test → score, CRUD against the database), that
  logic belongs behind @ref controller_artifacts,
  @ref controller_projects, or the orchestrator. The dialogs that
  currently violate this are catalogued in
  [Gap 6](@ref gap_widget_logic) — don't add new ones.
- **Honor the seam.** Bodies to the database, associations to the project
  — the [bodies-vs-associations rule](@ref bodies_vs_associations). A
  method that does both is in the wrong place.
- **Stream LLM output.** Any model call that can take more than a few
  seconds streams tokens to the caller; no silent blocking calls.
- **Hook bodies are Python 2.** Renode's embedded IronPython is 2.7 —
  test hook code in that dialect.
- The analyzer ruleset comes from the shared `iomt_lab_lints` package;
  keep `dart analyze` clean, then verify behavior anyway.

## How services are organized

Services live in `emulator_orchestrator/lib/services/`, grouped into
folders by **capability domain** — what the service *does*, not which
component uses it (the [synthesis](@ref synthesis) and
[auto-tune](@ref autotune) loops in `orchestrator/` consume services; they
don't own them). Put a new service in the folder that matches its job:

- **`hooks/`** — producing and classifying [hooks](@ref gloss_hook): the
  catalog, the classifiers (`hook_classifier`, `symbol_group_classifier`),
  the binding seeder, scope suggester, starter template, and the artifact
  library store.
- **`llm/`** — talking to the model and building prompts: the LLM client,
  profiles, hook generator, the recommender, and the last-run advisor.
- **`rag/`** — the retrieval index and chunker.
- **`analysis/`** — analysis over the call graph and run history:
  [fidelity](@ref gloss_fidelity), the coverage [frontier](@ref gloss_frontier),
  round-over-round deltas, call-graph reads. Mostly pure computation, with
  three I/O-touching exceptions: `call_graph_guard` hashes ELF bytes,
  `autotune_session_loader` reads report directories, and
  `artifact_census` reads the database.
- **`quality/`** — the hook-quality subsystem (scorer, test harness,
  progress runner, static analyzer, judge). Wired into `tool/`, tests, and
  two live dialogs (the LLM hook-gen dialog and the Hook DB dialog's Test
  button) — not the synthesis/auto-tune loops.
- **`comms/`** — the comms symbol classifier and the shared
  assignment merge both surfaces use (`comms_assignment_merge.dart`);
  the rest of comms lives in `orchestrator/comms/`.
- **`external/`** — external-tool integration and installers (Ghidra
  signatures, Ghidra/Ollama installers).

Services depend downward on models + database + sibling packages, and may
depend on each other across folders (e.g. `llm/recommendation_service`
reads `analysis/coverage_frontier`). Import siblings by relative path.

## Working on these docs

The docs are the architecture's source of truth
([docs-first](@ref gloss_docs_first)) — treat them as code:

1. **Changing the architecture? Edit the page first**, get it agreed, then
   change the code and update @ref current_vs_target / @ref roadmap.
2. **Mark every deviation.** Wherever a page describes a design the code
   has not reached yet, add a note in this exact format, immediately after
   the section it contradicts:

       @note **Deviation from the current code.**
       **Today:** how the repo works right now, naming real files.
       **Planned:** the change, linking its roadmap phase (e.g. @ref phase_p3).
       **Why:** the concrete problem the change fixes, in a sentence or two.

   One block per deviation. When the phase lands, delete the block (and
   the matching gap in @ref current_vs_target).
3. **Adding a page:** create `docs/pages/<name>.md` with a Doxygen page ID
   (`# Title {#page_id}`), add a `@subpage` line to `index.md` (that's
   what places it in the tree), keep it to *one* focus, and link every
   term of art to the @ref glossary — adding entries there as needed.
4. **Regenerate and check:** `doxygen docs/Doxyfile` from the repo root
   must produce no warnings (unresolved `@ref`s show up as warnings —
   treat them as errors). Open `docs/generated/html/index.html` to eyeball
   the result. Generated output is gitignored; commit only
   `docs/pages/` and the `Doxyfile`.

## Commits and PRs

Write commit messages that stand on their own — plain sentences about what
changed and why, no internal jargon. Branch from `main`, open a PR. The
engine packages resolve as hosted version pins, so shipping a
sibling-package change means bumping its version and publishing it to the
hosted repository before Resect's pin can pick it up (see the dev-setup
notes above).

## In short

Install with the script, override siblings locally, test with
`dart test`/`flutter test` plus the relevant tool script, keep the
dependency arrow one-way, put workflows behind controllers — and when you
change the architecture, change these pages first.
