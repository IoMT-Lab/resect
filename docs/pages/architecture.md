# The Architecture {#architecture}

Read this page first; every other page is a detail of it. It states
Resect's architecture as it should be — under the
[docs-first](@ref gloss_docs_first) rule, this page is the specification
and the code is brought into line with it. Where the code has not caught
up yet, a marked note on the relevant page says exactly how things work
today and why the change is planned; @ref current_vs_target collects all
of those gaps and @ref roadmap schedules the fixes.

## Two models, two controllers, one engine façade

Resect is organized MVC-style around exactly **two data
[models](@ref gloss_model)**, each with exactly **one
[controller](@ref gloss_controller)**, plus one façade for the emulation
engine. Everything else — screens, dialogs, CLI commands — is a *view* that
talks to these three objects:

    UI (Flutter widgets)                     CLI (bin/cli.dart)
          │         │        │                  │        │
          ▼         ▼        ▼                  ▼        ▼
    ProjectController   ArtifactController   EmulationOrchestrator
     (model #2:          (model #1:           (workflows: emulation,
      the project)        the artifact DB)     analysis, synthesis)
          │                    │                        │
          ▼                    ▼                        ▼
    EmulatorRepository   ArtifactDatabase      engine interfaces
      (.emu files)         (SQLite)                     │
                                                        ▼
                                               DartEngine → Renode

The three objects, one at a time:

- **@ref controller_artifacts** owns the
  [artifact database](@ref gloss_artifact_db) — [hook](@ref gloss_hook)
  bodies and firmware facts, global to the machine. Verbs: generate, store,
  query, bind, share.
- **@ref controller_projects** owns the open
  [project](@ref gloss_project) — one firmware re-hosting effort, saved as a
  `.emu` file. Verbs: create, open, save, close, and typed mutations.
- **`EmulationOrchestrator`** (the [orchestrator](@ref gloss_orchestrator))
  runs emulations. It composes an [engine](@ref gloss_engine) — the four
  interfaces [Renode](@ref gloss_renode) is driven through — with the
  emulation, analysis, and synthesis workflows, and it holds no persistent
  data of its own. @ref orchestrator_engine covers it in full.

Both the Flutter UI and the CLI drive **the same three objects**. There is
no UI-only business logic and no CLI-only business logic; if the two ever
behave differently, that is a bug (and historically it was a real one — see
@ref current_vs_target).

@note **Deviation from the current code.**
**Today:** neither controller exists as a single class. The artifact
duties are spread across `ArtifactLibraryService`, two large dialogs, and
three duplicated generate-and-bind sites; the project duties are spread
across `library_actions.dart`, `AutosaveController`, eight mirrored
Riverpod providers, and an `EmulatorWorkflow` inside the orchestrator.
**Planned:** the ArtifactController is built in @ref phase_p3; the
ProjectController in @ref phase_p2 and @ref phase_p5.
**Why:** with no single owner per model, every mutation path must be
written twice — once for the UI, once for the CLI — and the two have
already drifted apart (see @ref current_vs_target).

## The rule that separates the two models {#bodies_vs_associations}

One sentence separates the two models:

> Hook **bodies** are global and live in the artifact database. The
> **association** of a body with a [symbol](@ref gloss_symbol) — an
> [override](@ref gloss_override), [preference](@ref gloss_preference), or
> [binding](@ref gloss_binding) — is per-project and lives in the `.emu`
> file.

Why split it this way? A hook body like "return 0" or "forward this I2C read
to a virtual device" is useful across every project that ever meets a
similar function — so bodies are shared, deduplicated, and scored once,
globally. But *"symbol `bmp180_read_temp` in this firmware should use
artifact #42"* is an opinion about one specific re-hosting effort — it
belongs to the project, travels with the `.emu` file, and can differ between
two projects using the same firmware.

The controllers enforce the split mechanically:

- `ArtifactController` **returns** a [binding](@ref gloss_binding) value
  from its bind/generate calls. It never writes a `.emu` file.
- `ProjectController` **persists** that binding into the project. It never
  writes hook bodies into the database.

Storing a body in the project, or an association in the database, breaks
this rule — don't. The rule is what lets you understand either model
without reading the other.

## Where the pieces live

Both controllers and the orchestrator are plain Dart (no Flutter imports),
living in the `emulator_orchestrator` package. Because of that one
constraint, the CLI can do everything the UI can: `bin/cli.dart`
constructs the same three objects and calls the same methods. The Flutter
package (`emulator_ui`) contributes only views: widgets read state from
the controllers through thin Riverpod providers and call controller
methods on user actions. See @ref workspace_layout for the package map.

## What this architecture deliberately does NOT have

Simplicity is a stated project value — a simple architecture beats a
"better" one. So, by design:

- **No extra layers.** No facade-over-the-facade, no repository-per-table,
  no dependency-injection framework. Three objects.
- **No third model.** Manifests, snapshots, and reports are fields or files
  *of* the two models, not models of their own.
- **No data migration between the models.** The
  [bodies-vs-associations rule](@ref bodies_vs_associations) is enforced in
  code, not by moving data around.

## In short

Two models: the artifact database (global hook bodies + firmware facts) and
the project (per-effort associations + history). Two controllers, one per
model, both plain Dart, both driven identically by UI and CLI. One
orchestrator that runs emulations through the engine interfaces and owns no
data. One rule: bodies are global, associations are per-project. Everything
else on these pages is detail.
