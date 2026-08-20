# Object Groups {#symbol_groups}

Firmware rarely exposes hardware one function at a time. A single clock, timer,
or regulator usually shows up as a little family of functions that share a name
prefix — enable it, disable it, ask whether it's ready. Those functions are
*member functions of the same object*, and treating them together produces far
better [hooks](@ref gloss_hook) than handling each in isolation. This page
describes how Resect recognizes an [object group](@ref gloss_object_group) from
symbol names and hooks its members coherently. It complements per-[symbol](@ref gloss_symbol)
classification: without it, the [auto-tune](@ref gloss_autotune) loop could only
relate two symbols through call-graph adjacency, never through what they do.

## The worked example

Take three symbols a clock peripheral exposes:

    LL_RCC_LSI_Enable
    LL_RCC_LSI_Disable
    LL_RCC_LSI_IsReady

They are one object — the LSI clock — with three
[member roles](@ref gloss_member_role): turn on, turn off, report ready. Hooked
independently they drift: `IsReady` might be stubbed to a constant while
`Enable` does nothing, so the firmware's "enable then wait until ready" logic
either spins forever or skips setup. Hooked *as an object* they stay
consistent:

    LL_RCC_LSI_Enable   ->  write value=1   (scope LL_RCC_LSI)
    LL_RCC_LSI_Disable  ->  write value=0   (scope LL_RCC_LSI)
    LL_RCC_LSI_IsReady  ->  read            (scope LL_RCC_LSI)

Because all three share one [group scope](@ref gloss_group_scope)
(`LL_RCC_LSI`), the write from `Enable` lands in the same Renode Python-globals
namespace that `IsReady`'s read pulls from — so after `Enable` runs, `IsReady`
returns 1. That is the whole point of the shared [scope](@ref gloss_scope): it
turns three stubs into one small state machine.

## How a group is recognized

Grouping is name-based and runs only on non-comms symbols (see "Relationship to
comms" below). The parse is **verb-anchored**: it reads the name the way you'd
read a sentence — subject, then verb. For each symbol:

1. **Tokenize** the name, splitting on `_` *and* camelCase (reusing the comms
   classifier's tokenizer). `LL_RADIO_TIMER_EnableTimer1` →
   `[LL, RADIO, TIMER, Enable, Timer1]`; `IsEnabledTimer1` →
   `[…, Is, Enabled, Timer1]`.
2. **Scan left-to-right for the first role verb** (`Enable`, `Disable`, `Set`,
   `Get`, `Is…`, `Reset`, `Clear`, `Init`, `DeInit` — the is-family also
   matches the bare adjectives `Ready`, `Active`, `Valid`, `Present`). That
   verb *is* the member's role. Scanning left-to-right means `Is` wins in
   `IsEnabled` (a read), not `Enabled`.
3. **The object key is the tokens *before* the verb** (the subject). So
   `LL_RCC_LSI_Enable` and `LL_RCC_LSI_IsReady` both key to `LL_RCC_LSI`, and —
   crucially — `LL_RADIO_TIMER_EnableTimer1` and
   `LL_RADIO_TIMER_IsEnabledTimer1` both key to `LL_RADIO_TIMER_Timer1`
   (the digit-bearing token after the verb is appended — see "Numbered
   instances" below) regardless of how long the name is. The boundary
   follows *meaning*, not underscore position.
4. **Group by key.** Symbols with the same key are members of one object.

Two guards keep groups meaningful, and answer the obvious objection — *"won't
this lump together every `LL_` or `RCC_` function?"*:

- A group needs **at least two members**.
- The subject must have **at least two non-framework tokens** (`LL`/`HAL`
  tokens don't count, wherever they appear in the subject). So `LL_RCC_LSI`
  (→ `RCC`, `LSI`) is a valid object,
  but a bare `LL_RCC` is not — it never becomes one giant "RCC" group.

And a symbol with **no recognized verb has no derivable object, so it is simply
dropped** — which is why coincidental prefixes like `us_to` or `sfp_lock` never
form a group. (Because membership *requires* a recognized verb, every symbol
that does end up in a group has a real role; there are no "unknown" members to
filter out afterward.)

`LL_RCC_LSI_*` and `LL_RCC_HSE_*` therefore form two separate objects. And a
whole subsystem like `BLEPLAT_CNTR_*` — which the old positional rule swept into
one 52-member blob — decomposes into the real sub-objects the verb reveals:
`BLEPLAT_CNTR_Packet`, `BLEPLAT_CNTR_Sm`, `BLEPLAT_CNTR_Int`, and so on.

### Numbered instances

One wrinkle: a peripheral block often has several independent flags —
`EnableTimer1`, `EnableTimer2`, `IsEnabledTimer1`. If they all shared one scope,
`EnableTimer2`'s write would clobber `IsEnabledTimer1`'s read. So the key also
picks up any **digit-bearing token after the verb** (`Timer1`, `Timer2`), giving
each numbered instance its own scope (`LL_RADIO_TIMER_Timer1`,
`LL_RADIO_TIMER_Timer2`) while single-instance objects (the LSI clock, no digit)
keep one shared scope. `EnableTimer1` and `IsEnabledTimer1` still land on the
same `…_Timer1` scope, so the read still sees the write. Named sub-flags without
a digit (`CPUWakeupTimer` vs `BLEWakeupTimer`) are *not* separated — a known
limitation, no worse than treating them as one object.

## The default role-to-hook mapping

Each recognized role maps to a [catalog](@ref gloss_artifact) hook, all scoped
to the group key:

| Role (the verb) | Hook |
|---|---|
| Enable | write value 1 |
| Disable | write value 0 |
| Is… / IsReady / IsActive / IsEnabled | read (returns the stored value) |
| Get | read |
| Set | write value 1 |
| Reset / Clear | write value 0 |
| Init / DeInit | return 0 |

Only these unambiguous verbs are recognized. Genuinely ambiguous ones —
`Toggle`, `Config`, `Start`/`Stop`, `Wait`, `Request` — are deliberately *not*
mapped; a symbol whose only verb is one of those is left ungrouped rather than
guessed at. (Richer semantics for those is a candidate for a future
LLM-annotation step.)

## When the group is applied

In its default (untouched) state a group is **deterministic and
demand-driven** — no LLM, and nothing is hooked until it's needed; a scope
forced via `groupOverrides` instead pre-installs its member hooks at run
start (see "The LLM can steer groups" below). In the default state, during
a [synthesis](@ref gloss_synthesis) run, the
first time *any* member of a group faults on an
[unhandled access](@ref gloss_unhandled_access), the synthesizer force-installs
the coherent hook for **every** member of that group at once, with the shared
scope, and re-runs. It skips any member you've already given a
[forced override](@ref gloss_override) and any member that is
comms-virtualized. Each group is applied at most once per run, and shows up in
the [manifest](@ref gloss_manifest) as its own decision kind
(`group_override`), with the scope carried separately in the decision
source (`group_override:<scope>`) — so you can tell it apart from an
adjacency-driven fallback.

This is a different relationship from the auto-tune loop's adjacency escalation
(see @ref autotune), and it sits *beside* it: adjacency asks "what did this
function call that never ran?"; object grouping asks "what other functions
belong to the same thing?"

## The LLM can steer groups

During [auto-tune](@ref autotune), the recommendation LLM is shown the object
groups relevant to the round (scope, members, roles, and each group's current
state) and can act on a whole object with two recommendation kinds:

- **`set_group_override`** — force a group *proactively*: install its coherent
  member hooks at the start of the next run, before any member faults.
- **`clear_group_override`** — suppress a group: the synthesizer will not apply
  it even if a member faults, freeing its members for per-symbol handling. Use
  when the coherent stub is wrong for that object.

These decisions are stored on the [project](@ref gloss_project) as
`groupOverrides` (scope → forced/suppressed), so they persist across rounds and
reopen with the `.emu`. A scope the LLM never touches keeps the default
deterministic-on-fault behavior above. And because the map lives on the
project, a plain UI Synthesize run honors it too — forced scopes
pre-install at run start and suppressed scopes never fire. Only the CLI
`synthesize` command runs without the map (it never passes
`groupOverrides`), so headless one-shot synthesis is always the on-fault
default.

## Relationship to comms

[Comms virtualization](@ref gloss_comms_virtualization) is the other, older
form of grouping — it maps i2c/spi/uart symbols onto a bus interface. Object
grouping deliberately **excludes** every symbol the comms classifier already
claimed, and the synthesizer never group-hooks a comms-virtualized symbol. So
the two mechanisms never fight, and adding object groups cannot disturb the
bus path.

## In short

An object group is a family of member functions sharing a name prefix (the
group key), recognized by a verb-anchored parse with two guards (≥2 members,
≥2 non-framework tokens). Members get coherent, shared-scope hooks
(enable→write 1, disable→write 0, is-ready→read) so they behave as one small
state machine. The whole group is force-installed the first time any member
faults, deterministically — or proactively at run start when a group
override forces it — and never touches comms symbols.
