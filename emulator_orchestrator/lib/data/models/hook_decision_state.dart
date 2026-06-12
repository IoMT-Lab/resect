import 'comms_assignment.dart';
import 'emulator.dart';

/// Per-protocol bus snapshot the projection consumes — just the
/// fields it needs from the UI's `CommsProtocolConfig`. Defining a
/// record-typed alias here keeps the orchestrator free of any UI
/// import: callers (UI / CLI / tests) build this map themselves.
typedef CommsProtocolStatus = ({bool virtualized, int port});

/// Single read-only projection of every project-level overlay that
/// affects hook selection for a firmware, consumed by:
///
///   - the synthesizer (so headless and UI callers build it the same way),
///   - the pre-synthesis report tab (so the user sees what will happen
///     before they click Synthesize),
///   - the synthesis manifest builder (which extends each decision with
///     the runtime outcome — applied hook body hash, iteration index,
///     prior failed attempts, LLM telemetry).
///
/// Built by [buildHookDecisionState] — a pure synchronous function
/// that walks [Emulator]'s persisted overlays plus the live
/// `commsProtocolConfig`. **No artifact-DB I/O**: the projection
/// stays cheap and the UI / manifest builder can join in extra
/// artifact details (intrinsic score, body, origin) when they need
/// them.
///
/// The list is sorted by symbol name so diffs across reports are
/// stable.
class HookDecisionState {
  const HookDecisionState({
    required this.elfHash,
    required this.decisions,
  });

  /// SHA-256 of the firmware ELF this projection is for. Lets
  /// downstream consumers (manifest, diff view) verify they're
  /// reasoning about the same firmware.
  final String elfHash;

  /// One [HookDecision] per symbol with *any* overlay attached.
  /// Symbols with no overlay aren't included — the synthesizer's
  /// iteration loop handles those via the artifact DB's
  /// `intrinsicScore`-driven sort.
  final List<HookDecision> decisions;

  /// Helper: lookup a decision by symbol. Linear scan; the list is
  /// typically small (~tens to low hundreds of overlays per project).
  HookDecision? forSymbol(String symbol) =>
      decisions.cast<HookDecision?>().firstWhere(
            (d) => d?.symbol == symbol,
            orElse: () => null,
          );

  Map<String, dynamic> toJson() => {
        'elf_hash': elfHash,
        'decisions': decisions.map((d) => d.toJson()).toList(),
      };
}

/// Per-symbol record of which overlay layer drives the hook
/// selection for that symbol, plus a soft preference signal if set.
///
/// Fields are flat (rather than nested under a sealed-class union)
/// so the manifest's JSON shape can mirror this directly. Which
/// fields are populated depends on [kind] — see the per-field docs.
class HookDecision {
  const HookDecision({
    required this.symbol,
    required this.kind,
    this.artifactId,
    this.scope,
    this.body,
    this.fidelity,
    this.provenance,
    this.protocol,
    this.role,
    this.port,
    this.preferredArtifactId,
  });

  /// Symbol the decision is for. Matches a function name in the
  /// firmware's call graph.
  final String symbol;

  /// Which overlay layer drives this decision — see
  /// [HookDecisionKind] for the priority order. `none` means the
  /// only signal for this symbol is a soft `preference` hint.
  final HookDecisionKind kind;

  /// Populated for `override` and `binding`; the global artifact
  /// the decision points at. Null for `comms` (the body comes from
  /// the HookCatalog at synthesis time) and `resolved` (the body
  /// itself is in [body]).
  final int? artifactId;

  /// Renode `AddHookAtSymbol` scope (3rd arg). Populated for
  /// `override` (from `hookOverrideScopes`) and `comms` (the
  /// protocol name — `i2c`/`spi`/`uart`). Null elsewhere.
  final String? scope;

  /// Hook source body for `resolved` (warm-start) decisions, since
  /// those carry the code directly on the project. Null for every
  /// other kind — callers that need the body must resolve via
  /// artifactId against the artifact DB.
  final String? body;

  /// Per-symbol fidelity from the `HookBinding`. Populated only for
  /// `kind == binding`. 0.0–1.0; the synthesizer's candidate sort
  /// uses this as the primary key when present.
  final double? fidelity;

  /// Source label from the binding: `classifier:rule-N-foo`,
  /// `llm:gemma4:e4b`, `harness+judge`, `user`. Only set for
  /// `kind == binding`.
  final String? provenance;

  /// Comms protocol — `i2c` / `spi` / `uart`. Only set for
  /// `kind == comms`.
  final String? protocol;

  /// Comms role — `read` / `write` — or null if the protocol-match
  /// was role-ambiguous. Only set for `kind == comms`.
  final String? role;

  /// UDP port the comms-bus server listens on for this protocol.
  /// Only set for `kind == comms`; comes from the per-project
  /// `CommsProtocolConfig.port`.
  final int? port;

  /// Soft re-order hint from `hookPreferences[symbol]`. Set
  /// independently of [kind] — a symbol with a binding can also
  /// carry a preference (the preference promotes one artifact to
  /// index 0 in the iteration loop after the fidelity sort). Null
  /// when no preference is set for the symbol.
  final int? preferredArtifactId;

  HookDecision copyWith({
    int? preferredArtifactId,
  }) =>
      HookDecision(
        symbol: symbol,
        kind: kind,
        artifactId: artifactId,
        scope: scope,
        body: body,
        fidelity: fidelity,
        provenance: provenance,
        protocol: protocol,
        role: role,
        port: port,
        preferredArtifactId:
            preferredArtifactId ?? this.preferredArtifactId,
      );

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'kind': kind.name,
        if (artifactId != null) 'artifact_id': artifactId,
        if (scope != null) 'scope': scope,
        if (body != null) 'body': body,
        if (fidelity != null) 'fidelity': fidelity,
        if (provenance != null) 'provenance': provenance,
        if (protocol != null) 'protocol': protocol,
        if (role != null) 'role': role,
        if (port != null) 'port': port,
        if (preferredArtifactId != null)
          'preferred_artifact_id': preferredArtifactId,
      };
}

/// Priority order (high to low) of project-level overlays. The
/// builder walks the overlays in this order; the first one that
/// covers a given symbol owns the decision. `preference` is NOT in
/// this enum — it's a soft hint attached to whichever primary
/// decision applies (or to a `none` decision if no other overlay
/// touched the symbol).
enum HookDecisionKind {
  /// `Emulator.hookOverrides[symbol]` — forced artifact,
  /// pre-seeded, never iterated past. Fail-fatal at synthesis if
  /// the override causes an unhandled access.
  override,

  /// Comms-bus hook derived from `Emulator.commsAssignments[symbol]`
  /// plus the matching `CommsProtocolConfig` (must be virtualized).
  /// Pre-seeded with the protocol's scope so the per-protocol
  /// Python globals are shared.
  comms,

  /// `Emulator.hooks[symbol]` — warm-start body preserved from the
  /// last successful synthesis. Pre-seeded; iteration may still
  /// reach an unhandled access elsewhere.
  resolved,

  /// `Emulator.hookBindings[symbol]` — fidelity-scored compatibility
  /// binding. Drives the synthesizer's iteration sort but is NOT
  /// fail-fatal: if the bound artifact crashes, other candidates
  /// from the artifact DB are still tried.
  binding,

  /// No primary overlay touched this symbol — present only when a
  /// soft `preference` hint exists in isolation.
  none,
}

/// Build a [HookDecisionState] for the given [emulator] and
/// [elfHash]. Pure synchronous — walks the persisted overlays plus
/// the live [commsConfigs] and produces one [HookDecision] per
/// symbol with any state attached.
///
/// Soft preferences attach to whichever primary decision already
/// exists for their symbol; preferences that stand alone become a
/// `kind: none` decision with `preferredArtifactId` set.
HookDecisionState buildHookDecisionState({
  required Emulator emulator,
  required String elfHash,
  required Map<CommsClass, CommsProtocolStatus> commsConfigs,
}) {
  final byCommSymbol = <String, HookDecision>{};
  final seen = <String>{};

  // 1) Forced overrides — top priority, fail-fatal at synthesis.
  for (final entry in emulator.hookOverrides.entries) {
    final rawScope = emulator.hookOverrideScopes[entry.key];
    byCommSymbol[entry.key] = HookDecision(
      symbol: entry.key,
      kind: HookDecisionKind.override,
      artifactId: entry.value,
      scope: (rawScope == null || rawScope.isEmpty) ? null : rawScope,
    );
    seen.add(entry.key);
  }

  // 2) Comms hooks — pre-seeded only when the protocol is
  //    virtualized. The body itself is materialised by HookCatalog
  //    at synthesis time; the projection just captures the
  //    protocol/role/port triple.
  for (final entry in emulator.commsAssignments.entries) {
    if (seen.contains(entry.key)) continue;
    if (entry.value.protocol == CommsClass.unclassified) continue;
    final cfg = commsConfigs[entry.value.protocol];
    if (cfg == null || !cfg.virtualized) continue;
    byCommSymbol[entry.key] = HookDecision(
      symbol: entry.key,
      kind: HookDecisionKind.comms,
      protocol: entry.value.protocol.name,
      role: entry.value.role?.name,
      port: cfg.port,
      scope: entry.value.protocol.name,
    );
    seen.add(entry.key);
  }

  // 3) Warm-start resolved hooks from the previous synthesis run.
  for (final entry in emulator.hooks.entries) {
    if (seen.contains(entry.key)) continue;
    byCommSymbol[entry.key] = HookDecision(
      symbol: entry.key,
      kind: HookDecisionKind.resolved,
      body: entry.value,
    );
    seen.add(entry.key);
  }

  // 4) Fidelity-scored bindings — the per-project compatibility
  //    overlay. The synthesizer's iteration sort consumes this
  //    layer; UI sees provenance + fidelity for each row.
  for (final entry in emulator.hookBindings.entries) {
    if (seen.contains(entry.key)) continue;
    byCommSymbol[entry.key] = HookDecision(
      symbol: entry.key,
      kind: HookDecisionKind.binding,
      artifactId: entry.value.artifactId,
      fidelity: entry.value.fidelity,
      provenance: entry.value.provenance,
    );
    seen.add(entry.key);
  }

  // 5) Soft preferences — attach to whichever primary decision
  //    exists for the symbol, OR create a `kind: none` decision
  //    when the preference stands alone.
  for (final entry in emulator.hookPreferences.entries) {
    final existing = byCommSymbol[entry.key];
    if (existing != null) {
      byCommSymbol[entry.key] =
          existing.copyWith(preferredArtifactId: entry.value);
    } else {
      byCommSymbol[entry.key] = HookDecision(
        symbol: entry.key,
        kind: HookDecisionKind.none,
        preferredArtifactId: entry.value,
      );
    }
  }

  final sortedDecisions = byCommSymbol.values.toList()
    ..sort((a, b) => a.symbol.compareTo(b.symbol));
  return HookDecisionState(
    elfHash: elfHash,
    decisions: sortedDecisions,
  );
}
