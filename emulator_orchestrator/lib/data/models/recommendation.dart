/// Structured edit proposed by the closed-loop LLM orchestrator.
///
/// Each round of the auto-tune loop, the [RecommendationService] asks
/// the LLM for a list of [Recommendation]s grounded in the prior
/// round's manifest + current overlays + metrics. Each entry is a
/// typed action the user reviews (Accept / Reject / Edit) before the
/// orchestrator's apply step touches any overlay provider.
///
/// **Wire format.** Recommendations cross the LLM boundary as JSON
/// with a `kind` discriminator field naming the subclass. See
/// [Recommendation.fromJson] for the dispatch table; see each
/// subclass's `fromJson` for the per-kind payload shape.
///
/// **Why sealed.** A closed set of recommendation kinds keeps the
/// Apply handler exhaustive — the compiler enforces a switch over
/// every kind, so adding a new recommendation type forces the
/// orchestrator's apply pipeline to be updated in lockstep.
sealed class Recommendation {
  const Recommendation({required this.rationale});

  /// Short LLM explanation for why this recommendation should be
  /// applied. Surfaced to the user in the recommendation review UI
  /// next to the per-row Accept / Reject / Edit controls. Typically
  /// one sentence; not a stable identifier.
  final String rationale;

  /// Stable wire identifier for the recommendation's kind. Decoupled
  /// from Dart class names so renaming a class doesn't silently break
  /// LLM output / snapshot persistence.
  String get kind;

  /// Serialize this recommendation to its JSON wire form. Always
  /// includes the `kind` and `rationale` fields plus the
  /// subclass-specific payload.
  Map<String, dynamic> toJson();

  /// Decode a JSON object into a typed [Recommendation].
  ///
  /// Returns `null` for unknown `kind` values rather than throwing —
  /// this is the forward-compat path so a newer LLM emitting an
  /// unknown kind can be safely dropped from the batch (with a log
  /// line at the caller) instead of bringing down the entire round's
  /// recommendations.
  static Recommendation? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String?;
    final rationale = (json['rationale'] as String?) ?? '';
    switch (kind) {
      case SetForcedOverride.kindName:
        return SetForcedOverride(
          rationale: rationale,
          symbol: json['symbol'] as String,
          artifactId: json['artifact_id'] as int,
          scope: json['scope'] as String?,
        );
      case ClearForcedOverride.kindName:
        return ClearForcedOverride(
          rationale: rationale,
          symbol: json['symbol'] as String,
        );
      case SetPreference.kindName:
        return SetPreference(
          rationale: rationale,
          symbol: json['symbol'] as String,
          artifactId: json['artifact_id'] as int,
        );
      case GenerateCustomHook.kindName:
        return GenerateCustomHook(
          rationale: rationale,
          symbol: json['symbol'] as String,
          intent: json['intent'] as String?,
        );
      case AdjustIterationCap.kindName:
        return AdjustIterationCap(
          rationale: rationale,
          newValue: json['new_value'] as int,
        );
      case SetGroupOverride.kindName:
        return SetGroupOverride(
          rationale: rationale,
          scope: json['scope'] as String,
        );
      case ClearGroupOverride.kindName:
        return ClearGroupOverride(
          rationale: rationale,
          scope: json['scope'] as String,
        );
      default:
        return null;
    }
  }
}

/// Pin [symbol] to the catalog hook identified by [artifactId] as a
/// forced override. Maps to `hookOverridesProvider[symbol] = artifactId`
/// in the apply step, plus an atomic write of `scope` (or removal
/// from the scopes map when `scope == null`).
class SetForcedOverride extends Recommendation {
  const SetForcedOverride({
    required super.rationale,
    required this.symbol,
    required this.artifactId,
    this.scope,
  });

  static const kindName = 'set_forced_override';
  @override
  String get kind => kindName;

  final String symbol;
  final int artifactId;
  final String? scope;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'symbol': symbol,
        'artifact_id': artifactId,
        if (scope != null) 'scope': scope,
      };
}

/// Remove the forced-override pin for [symbol]. Maps to
/// `hookOverridesProvider.remove(symbol)` plus an atomic removal from
/// the scopes map.
class ClearForcedOverride extends Recommendation {
  const ClearForcedOverride({
    required super.rationale,
    required this.symbol,
  });

  static const kindName = 'clear_forced_override';
  @override
  String get kind => kindName;

  final String symbol;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'symbol': symbol,
      };
}

/// Bias the iteration sort toward a specific catalog artifact for
/// [symbol] without locking it in. Maps to
/// `hookPreferencesProvider[symbol] = artifactId`.
class SetPreference extends Recommendation {
  const SetPreference({
    required super.rationale,
    required this.symbol,
    required this.artifactId,
  });

  static const kindName = 'set_preference';
  @override
  String get kind => kindName;

  final String symbol;
  final int artifactId;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'symbol': symbol,
        'artifact_id': artifactId,
      };
}

/// Author a fresh hook template via [LlmHookGenerator] for [symbol].
///
/// The orchestrator's apply step handles this kind specially — it
/// invokes the LLM hook generator, gets back the new artifact id,
/// and seeds a [HookBinding] into the binding provider with
/// provenance `llm:auto-tune-r<round>`. Subsequent recommendations
/// in the same batch can reference the new artifact by symbol.
///
/// [intent] is an optional free-text hint that gets prepended to the
/// hook-gen prompt (e.g. "return the 64MHz clock value", "model the
/// busy bit as flipping every 10 calls").
class GenerateCustomHook extends Recommendation {
  const GenerateCustomHook({
    required super.rationale,
    required this.symbol,
    this.intent,
  });

  static const kindName = 'generate_custom_hook';
  @override
  String get kind => kindName;

  final String symbol;
  final String? intent;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'symbol': symbol,
        if (intent != null) 'intent': intent,
      };
}

/// Change the synthesizer's per-run iteration cap. Maps to a write
/// on the iteration-cap provider; takes effect for the next run.
class AdjustIterationCap extends Recommendation {
  const AdjustIterationCap({
    required super.rationale,
    required this.newValue,
  });

  static const kindName = 'adjust_iteration_cap';
  @override
  String get kind => kindName;

  final int newValue;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'new_value': newValue,
      };
}

/// Force the whole object group identified by [scope] — install the
/// coherent, shared-scope hook for every member at once (enable→write 1,
/// is-ready→read, …). Maps to `groupOverrides[scope] = forced` in the apply
/// step; the synthesizer pre-installs the group's member hooks. Lets the LLM
/// act on a recognized peripheral as a unit instead of one symbol at a time.
/// See `SymbolGroupClassifier` and the `symbol_groups` docs page.
class SetGroupOverride extends Recommendation {
  const SetGroupOverride({
    required super.rationale,
    required this.scope,
  });

  static const kindName = 'set_group_override';
  @override
  String get kind => kindName;

  /// The group key (e.g. `LL_RCC_LSI`), from the object-groups prompt section.
  final String scope;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'scope': scope,
      };
}

/// Stop the object group identified by [scope] from being applied — its
/// members fall back to normal per-symbol handling, and the synthesizer will
/// not auto-apply the group even if a member faults. Maps to
/// `groupOverrides[scope] = suppressed`. Use when the coherent stub is wrong
/// for the object.
class ClearGroupOverride extends Recommendation {
  const ClearGroupOverride({
    required super.rationale,
    required this.scope,
  });

  static const kindName = 'clear_group_override';
  @override
  String get kind => kindName;

  final String scope;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'rationale': rationale,
        'scope': scope,
      };
}
