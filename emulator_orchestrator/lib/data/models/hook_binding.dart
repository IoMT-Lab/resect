/// A per-symbol record of which artifact this project has chosen as the
/// preferred substitute for a given function, plus how strongly that
/// choice is supported by evidence.
///
/// Bindings are the per-project compatibility overlay: same artifact body
/// (e.g. the catalog `return 0` template) can carry fidelity 0.0 against
/// one symbol (no binding — falls back to the artifact's intrinsic floor)
/// and 0.25 against another (classifier rule 2 matched the decomp). They
/// sit alongside [hookOverrides] (forced) and [hookPreferences] (soft
/// re-order) on the [Emulator] data model and serialize into the `.emu`
/// JSON as the `hook_bindings` map.
///
/// `provenance` is a free-form string distinguishing the binding's source
/// — `classifier:rule<N>` / `llm:<modelTag>` / `harness+judge` / `user`.
/// The synthesizer doesn't interpret it; downstream consumers (the
/// pre-synthesis report, the manifest, the Hook Database dialog) use it
/// to label rows for the user.
class HookBinding {
  const HookBinding({
    required this.artifactId,
    required this.fidelity,
    required this.provenance,
    required this.createdAt,
    this.scope,
  });

  /// Primary-key id of the artifact in the global artifact DB.
  final int artifactId;

  /// 0.0–1.0. The synthesizer's iteration uses this (when present) as the
  /// candidate-sort key, falling back to `Artifacts.intrinsicScore` for
  /// candidates without a matching binding.
  final double fidelity;

  /// Source label — `classifier:rule3` / `llm:gemma4:e4b` / `harness+judge` /
  /// `user`. Used by reporters; opaque to the synthesizer.
  final String provenance;

  /// When this binding was recorded. Useful for downstream UIs that need
  /// to surface "this binding is stale" hints once Stage 3 (harness +
  /// scorer) lands.
  final DateTime createdAt;

  /// Renode `AddHookAtSymbol` scope (the 3rd arg) that should be used
  /// when this binding's hook is deployed. Null = no scope (Renode
  /// spins up a fresh Python interpreter per call). Stateful hooks
  /// — counters, busy-ready toggles, comms read/write pairs — need a
  /// non-null scope or their module-level state evaporates between
  /// invocations. Stateless hooks ignore scope.
  ///
  /// Catalog templates set this correctly: `returnHook` → null,
  /// `incrementHook(fn)` → fn (per-symbol isolation), comms hooks →
  /// protocol name (shared across an i2c/spi/uart bus). The classifier
  /// surfaces it via `cls.hook.scope`; the seeder threads it onto the
  /// binding.
  final String? scope;

  HookBinding copyWith({
    int? artifactId,
    double? fidelity,
    String? provenance,
    DateTime? createdAt,
    String? scope,
    bool clearScope = false,
  }) =>
      HookBinding(
        artifactId: artifactId ?? this.artifactId,
        fidelity: fidelity ?? this.fidelity,
        provenance: provenance ?? this.provenance,
        createdAt: createdAt ?? this.createdAt,
        scope: clearScope ? null : (scope ?? this.scope),
      );

  Map<String, dynamic> toJson() => {
        'artifact_id': artifactId,
        'fidelity': fidelity,
        'provenance': provenance,
        'created_at': createdAt.toIso8601String(),
        if (scope != null && scope!.isNotEmpty) 'scope': scope,
      };

  factory HookBinding.fromJson(Map<String, dynamic> json) {
    // Normalize empty-string scope to null so callers don't have to
    // special-case both. Mirrors how `hookOverrideScopes` is treated
    // at the synthesizer's pre-seed sites.
    final rawScope = json['scope'] as String?;
    final scope = (rawScope == null || rawScope.isEmpty) ? null : rawScope;
    return HookBinding(
      artifactId: json['artifact_id'] as int,
      fidelity: (json['fidelity'] as num).toDouble(),
      provenance: json['provenance'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      scope: scope,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HookBinding &&
          other.artifactId == artifactId &&
          other.fidelity == fidelity &&
          other.provenance == provenance &&
          other.createdAt == createdAt &&
          other.scope == scope);

  @override
  int get hashCode =>
      Object.hash(artifactId, fidelity, provenance, createdAt, scope);

  @override
  String toString() =>
      'HookBinding(artifactId: $artifactId, fidelity: ${fidelity.toStringAsFixed(2)}, '
      'provenance: $provenance${scope != null ? ', scope: $scope' : ''})';
}
