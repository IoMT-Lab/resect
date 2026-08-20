# Hook Overlays: Overrides, Preferences, Bindings {#hook_overlays}

Five maps on the [project](@ref gloss_project) decide which
[hook](@ref gloss_hook) a [symbol](@ref gloss_symbol) gets. Collectively
they're called the [overlays](@ref gloss_overlay). Mixing them up is the
easiest way to misread the [synthesizer](@ref gloss_synthesizer), so this
page does one thing: define each map, then show the exact order the
synthesizer consults them.

## The five maps

**`hookOverrides` — "this symbol MUST use this artifact."**
Symbol → artifact id. The strongest statement. Overrides are installed
before the run starts, and if an overridden hook still fails, the run
*fails* — the synthesizer will not quietly try something else, because you
told it not to. Set from the Call Graph tab's metadata panel, the Hook
Database dialog, or an accepted auto-tune
[recommendation](@ref gloss_recommendation).

**`hookOverrideScopes` — "and anchor it here."**
Symbol → [scope](@ref gloss_scope) string, the Renode anchoring hint that
travels with an override when a bare symbol name is ambiguous.

**`hookPreferences` — "try this one first."**
Symbol → artifact id, but soft: when the synthesizer pauses at this symbol
and goes looking for candidates, the preferred artifact jumps the queue.
If it doesn't work, the synthesizer moves on to other candidates. A
preference can never fail a run.

**`hookBindings` — "this artifact is known to suit this symbol this well."**
Symbol → [binding](@ref gloss_binding) (artifact id +
[fidelity](@ref gloss_fidelity) estimate + [provenance](@ref gloss_provenance)
+ optional scope). Bindings are the scored knowledge base that candidate
ranking is built on — produced by the [classifier](@ref gloss_classifier)
seeding pass, by LLM authoring, or by hand.

**`groupOverrides` — "treat this whole object this way."**
[Group scope](@ref gloss_group_scope) →
forced/suppressed (persisted as `group_overrides` in the `.emu`).
`forced` pre-installs the group's coherent member hooks at the start of
every run; `suppressed` stops the group from being applied even when a
member faults; a scope absent from the map keeps the default
apply-on-first-fault behavior. Set by accepted auto-tune group
recommendations (`set_group_override` / `clear_group_override`) — see
@ref symbol_groups.

And one map that is *not* an opinion but a cache: **`hooks`** — symbol →
resolved Python code from the last run, the
[warm start](@ref gloss_warm_start). The write-back fires whenever a run
ends with a non-empty resolved-hook map and the caller asked for
persistence — cold-start auto-tune rounds pass
`persistResolvedHooks: false` so independent rounds don't overwrite it.

## Who wins: the order of application

At the start of a synthesis run (`SynthesizerWorkflow.run`,
`emulator_orchestrator/lib/orchestrator/workflows/synthesizer_workflow.dart`),
hooks are pre-seeded in this order:

1. **Overrides** — installed first, recorded in the
   [manifest](@ref gloss_manifest) with source `user.hookOverrides`.
2. **Comms hooks** — the forwarding hooks from
   @ref comms_virtualization. They respect overrides but replace anything
   else on their symbols.
3. **Warm-start `hooks`** — everything left over from last time, lowest
   priority of the pre-seeded layers.
4. **Forced object groups** — every scope `groupOverrides` marks `forced`
   gets its coherent member hooks installed proactively, skipping members
   an override or comms hook already claimed (see @ref symbol_groups).

Then, *during* the run, each pause is triaged before any ranking: a fault
at a symbol whose *forced override* is installed fails the run on the spot
(the override already failed — trying alternatives would defy it), and the
first fault of any member of a recognized, non-suppressed object group
force-installs the whole group and re-runs. Only an unhooked symbol that
survives both reaches candidate gathering:

5. **Preference first** — if `hookPreferences` names an artifact for the
   paused symbol, it's tried before anything else.
6. **Then by score** — remaining candidates are sorted by the binding's
   fidelity when a binding exists, otherwise by the artifact's
   [intrinsic score](@ref gloss_intrinsic_score). (In SQL terms:
   `COALESCE(binding.fidelity, artifact.intrinsicScore, 0.0)`.)
7. **LLM next, generics last** — as soon as the *next untried* candidate
   in that ranked list scores below 0.5 (or the list runs out), the
   [LLM fallback](@ref gloss_llm_fallback) authors a new hook; any
   remaining low-scoring generics are tried only after the LLM has had
   its turn.

## A worked example

Suppose your project has, for the symbol `bmp180_read_temp`:

- a binding to artifact #17 (a classifier-seeded `return 0` template,
  fidelity 0.4), and
- a preference for artifact #42 (an LLM-authored model of the sensor).

The run pauses at `bmp180_read_temp`. The synthesizer tries #42 first (the
preference), and only if that attempt fails does it fall back to ranking —
where #17's 0.4 makes it a weak candidate, likely followed by the LLM
fallback. Now add an *override* to artifact #42 instead: #42 is installed
before the firmware even starts, and if it faults, the run stops and tells
you your override is wrong.

Rule of thumb: **override** when you know, **prefer** when you suspect,
and let **bindings** carry what the tools have learned.

## Who writes these maps

- You, from the UI (metadata panel, Hook Database dialog).
- The classifier seeding pass on project open (bindings only, UI only — see
  @ref pre_synthesis).
- Accepted [auto-tune](@ref gloss_autotune) recommendations — applied
  through one shared function (`applyRecommendationsToOverlays` in
  `emulator_orchestrator/lib/orchestrator/recommendation_overlay_applier.dart`,
  which mutates `groupOverrides` too) so the UI and CLI can't drift.

The synthesizer itself is *not* on the list: the bindings it seeds for
hooks the LLM fallback authors live in a run-local copy and are never
written back to the project's `hookBindings`.

All of it is persisted in the `.emu` — see @ref model_projects.

## In short

Overrides force (and can fail a run), preferences nudge (and can't),
bindings score, group overrides steer whole objects, warm-start caches.
Pre-seed order: overrides → comms → warm start → forced groups; at each
pause: failed-override bailout → group escalation → preference → best
score → LLM.
