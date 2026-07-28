# Resect Documentation

Welcome. Resect is a workbench for *re-hosting* embedded firmware: taking a
binary that was built to run on a physical microcontroller and getting it to
run — usefully and measurably — inside the [Renode](@ref gloss_renode)
emulator instead. When the firmware touches hardware that the emulator
doesn't model, Resect patches around the gap with small Python functions
called [hooks](@ref gloss_hook), and it uses a local LLM to help write,
choose, and tune those hooks.

These pages are the map to the whole system. They are written for someone
who has never seen the code before, and every term of art links to the
[glossary](@ref glossary). If you read nothing else, read
@ref architecture first.

## These docs lead; the code follows {#docs_first_policy}

This documentation is **the source of truth for Resect's architecture**. We
follow a [docs-first](@ref gloss_docs_first) rule:

1. When we want to change how the system is put together, we change these
   pages *first*.
2. Then we change the code to match the pages.

That means some pages describe a design the code hasn't fully caught up to
yet. Wherever that's the case, the page carries a marked note — always
titled **"Deviation from the current code"** — that states how the code
works today, what change is planned (with its @ref roadmap phase), and
why. @ref current_vs_target collects every such gap in one place.

Two writing rules keep the docs healthy — follow them when you edit:

- **One page, one focus.** If a page starts covering two things, split it.
  More pages beat long pages.
- **Link every term.** The first time a page uses a term of art, link it to
  its @ref glossary entry. If the term isn't in the glossary yet, add it.

## How to read these docs

If you're brand new, read Part I in order, then @ref architecture. If you're
here to work on a specific subsystem, jump straight to its page in Part III —
each one stands alone.

### Part I — Getting oriented

- @subpage getting_started — install Resect and run your first synthesis in
  about five minutes.
- @subpage where_things_live — a "pick a process, get the files" index for
  navigating the layered codebase.
- @subpage workspace_layout — the packages in this repository and the sibling
  repositories they depend on.
- @subpage storage_map — every file and database Resect writes on disk, and
  why it lives where it does.
- @subpage cli — driving Resect headlessly from the command line.

### Part II — The architecture

- @subpage architecture — the two data models, their two controllers, and
  the one rule that separates them.
- @subpage model_artifacts — data model #1: the artifact database (hook
  bodies and firmware facts).
- @subpage controller_artifacts — the controller for the artifact database:
  generate, store, query, bind, share.
- @subpage model_projects — data model #2: the project (a `.emu` file).
- @subpage controller_projects — the controller for projects: one lifecycle,
  driven identically by the UI and the CLI.
- @subpage orchestrator_engine — the third object: the orchestrator, its
  workflows, and the engine interfaces that drive Renode.
- @subpage current_vs_target — where today's code differs from this
  architecture, gap by gap.
- @subpage roadmap — the ordered, phased plan to close those gaps.

### Part III — How things work

- @subpage hook_lifecycle — the life of a hook, from generation to running
  inside Renode.
- @subpage hook_overlays — overrides, preferences, and bindings: the three
  maps that decide which hook a symbol gets.
- @subpage symbol_groups — recognizing peripheral "objects" from symbol
  names and hooking their member functions together.
- @subpage synthesis — a single synthesizer run, iteration by iteration.
- @subpage autotune — the closed loop that runs synthesis repeatedly and
  lets an LLM tune the setup between rounds.
- @subpage comms_virtualization — how firmware I2C/SPI/UART traffic is
  forwarded out of the emulator to a virtual device.

### Part IV — Appendices

- @subpage contributing — dev setup, tests, and conventions (including how
  to add a page to these docs).
- @subpage glossary — every term of art, defined once.

## Regenerating this site

From the repository root:

    doxygen docs/Doxyfile

then open `docs/generated/html/index.html`. The generated output is
gitignored; only the page sources under `docs/pages/` and the `Doxyfile` are
committed.
