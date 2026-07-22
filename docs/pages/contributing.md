# Contributing {#contributing}

How to set up a dev environment, run the tests, and keep the codebase (and
these docs) in the shape the @ref architecture describes.

## Dev setup

1. Clone this repo and run `./install.sh` (see @ref getting_started).
2. For work that touches the sibling packages, clone them next to this
   repo (`renode-dart`, `callgraph-dart`, `hooks-dart`, `signatures-dart`,
   `lints-dart`) and create the git-ignored `pubspec_overrides.yaml`
   redirecting to them — @ref workspace_layout explains the wiring and its
   pitfalls.
3. LLM features need Ollama, signature features need Ghidra; both install
   from **Tools ▸ System Configuration** inside the app. Machine-local
   paths and module toggles live in `resect.config`.

## Running things

    ./run.sh                 # the desktop app (add --regen after DB schema edits)
    dart run emulator_orchestrator:cli --help    # headless

The CLI commands have their own page: @ref cli.

## Tests

    cd emulator_orchestrator && dart test        # logic, models, engine
    cd emulator_ui && flutter test               # widgets, UI loops

Slower, environment-dependent checks (live Ollama, Ghidra, Renode) live as
scripts in `emulator_orchestrator/tool/` rather than in `test/` — run the
relevant one when you touch its subsystem.

One rule: **a clean analyzer is not a passing test, and a passing test is
not a working feature.** Before calling a change done, run the
concrete thing — the CLI command, the UI flow, the tool script — and watch
it do what you claimed.

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
changed and why, no internal jargon. Branch from `main`, open a PR;
sibling-package changes need their pins updated to pushed commits before a
clean build passes (see [known debts](@ref known_debts)).

## In short

Install with the script, override siblings locally, test with
`dart test`/`flutter test` plus the relevant tool script, keep the
dependency arrow one-way, put workflows behind controllers — and when you
change the architecture, change these pages first.
