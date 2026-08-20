# The ProjectController {#controller_projects}

This page is the specification of the
[controller](@ref gloss_controller) for
[model #2](@ref model_projects) — the single class that owns the open
[project](@ref gloss_project), for the UI and the CLI alike.

@note **Deviation from the current code.**
**Today:** this controller does not exist as one class. Create, open,
save, and close are free functions in
`emulator_ui/lib/presentation/screens/library/library_actions.dart`; the
open project is mirrored into eight separate Riverpod providers kept in
sync by `AutosaveController`
(`emulator_ui/lib/providers/autosave_provider.dart`); there are two
restore paths that must agree; and the CLI builds its own project edits
by reassigning the (immutable) `Emulator` via `copyWith` — no typed
mutations, no controller. The closest ancestor is `EmulatorWorkflow`
(`emulator_orchestrator/lib/orchestrator/workflows/emulator_workflow.dart`),
which already wraps `EmulatorRepository` and tracks dirty state.
**Planned:** @ref phase_p2 removes the duplicate restore path;
@ref phase_p5 renames `EmulatorWorkflow` to `ProjectController` and gives
it the full surface below.
**Why:** two live copies of the same state (the `Emulator` and the
mirrored providers) can and do disagree, and every project operation must
currently be implemented once for the UI and again for the CLI.

## The job

`ProjectController` holds exactly one thing: the currently open `Emulator`
object. Every read of project state goes through it; every mutation is one
of its typed methods. It lives in the `emulator_orchestrator` package
(plain Dart) so that `bin/cli.dart` constructs and drives the very same
class the Flutter app does — one implementation of every project
operation, shared by both.

## Lifecycle

    create({name, elfPath, replPath})   // new project
    open(path)                          // load a .emu
    save() / saveAs(path)
    close()

`open()` is the **single restore path**. It loads the `.emu`, strips a
cached [call graph](@ref gloss_call_graph) whose SHA-256 stamp doesn't
match the project's firmware — the load-time check `openEmulator` already
performs today (`library_actions.dart`) — backfills
[bindings](@ref gloss_binding) for user-authored replacement artifacts,
runs the [classifier](@ref gloss_classifier) seeding pass for symbols that
have no binding yet (both via @ref controller_artifacts), sets the one
in-memory `Emulator`, and emits one change event. Nothing else in the
system restores project state — the duplicate restore listener that exists
today is deleted in phase @ref phase_p2.

## Typed mutations

No caller ever pokes fields on the `Emulator` directly. Each mutation is a
method that applies the change, marks the project dirty, and emits a change
event:

    setOverride(symbol, artifactId) / clearOverride(symbol)
    setOverrideScope(symbol, scope)
    setPreference(symbol, artifactId)
    setBinding(symbol, binding)          // persists what ArtifactController returned
    applyRecommendations(decisions)      // the auto-tune apply step
    setCommsAssignment(symbol, assignment)
    setSynthesisResult(result)
    setExecutedSymbols(symbols)
    appendRoundSnapshot(snapshot)
    addDocument(path) / removeDocument(id)

Note the division of labor with the
[ArtifactController](@ref controller_artifacts):
`ArtifactController.bindHook(...)` *returns* a binding;
`ProjectController.setBinding(...)` *persists* it. See the
[bodies-vs-associations rule](@ref bodies_vs_associations).

## One `Emulator`, no shadows

The controller's state is exposed to the UI as **one** Riverpod provider
(`currentProjectProvider`) whose value is the immutable `Emulator`. Widgets
subscribe to just the slice they render:

    ref.watch(currentProjectProvider.select((p) => p.hookOverrides))

Two implementation rules matter enough to write down:

1. **The `Emulator` is replaced, never modified in place.** Every mutation
   builds a new object via `copyWith`. This is required for the UI to
   update at all: `select()` compares references, so an object modified in
   place looks unchanged, no rebuild fires, and the UI silently shows
   stale data. This is the riskiest detail of phase @ref phase_p5.
2. **No shadow providers.** The eight per-field StateProviders that
   currently mirror project fields are replaced by `select()` projections
   of the one provider. There is nothing to "gather" or "restore" between
   representations, so today's `AutosaveController.gatherState` /
   `restoreArtifacts` shuttle disappears.

## Autosave

Autosave becomes a debounced call to `save()` on change events, with three
preserved behaviors: it only runs when the user has autosave enabled; it
**skips projects that have never been saved** (no path yet) — a
never-saved scratch project must not write files until you choose a path;
and it **refuses to persist a call graph that doesn't belong to the ELF
being saved**, dropping an already-poisoned one so a save actively cleans
the project (today: `AutosaveController.gatherState` in
`autosave_provider.dart`).

## How the CLI drives it

The CLI does exactly what the UI does, minus the widgets:

    final controller = ProjectController(repository);
    await controller.open(emuPath);
    controller.setOverride('SystemClock_Config', 42);
    // ... run synthesis via EmulationOrchestrator ...
    await controller.save();

If a behavior exists in the UI but can't be reached this way from
`bin/cli.dart`, that's a regression against this page.

## In short

One class, one open `Emulator`, one restore path, typed mutations that mark
dirty and emit events, one Riverpod provider with `select()` for the UI,
and a CLI that calls the identical methods. Built by renaming
`EmulatorWorkflow` and absorbing the logic that currently lives in
`library_actions.dart` and `AutosaveController`.
