/// The detected (or user-declared) identity of the MCU a project's
/// firmware targets — the key that unlocks the vendor SDK/document
/// corpus for synthesis and auto-tune.
///
/// Detection lives in `services/chip/chip_detector.dart`; this file is
/// the pure model plus [ChipNameParser], the single part-name grammar
/// shared by SVD filename stems, platform-file names, and user
/// overrides.
library;

/// Which detection probe produced a piece of evidence.
enum ChipSignal {
  /// An `ApplySVD @<url>` line in the platform .repl — names the exact
  /// part and hands us a register-map URL. Strongest signal.
  svdUrl,

  /// Fingerprint match against the Renode-bundled part-named platform
  /// files (cpuType + memory layout + vendor-branded peripheral types).
  platformFingerprint,

  /// A part-shaped token in a repl/.emu/ELF filename.
  filename,

  /// Vendor-prefixed firmware symbols (HAL_/LL_, nrf_/nrfx_, …).
  /// Vendor-level only — never names a part.
  symbolPrefix,

  /// The user typed/picked it. Beats everything, never clobbered.
  userOverride,
}

/// One piece of detection evidence, kept so the UI can show WHY Resect
/// believes the chip is what it says (and so conflicts are auditable).
class ChipEvidence {
  const ChipEvidence({
    required this.signal,
    required this.detail,
    required this.weight,
  });

  final ChipSignal signal;

  /// Human-readable: `ApplySVD https://…/STM32WB05.svd`,
  /// `matched bundled platform nrf52840.repl`, `7 HAL_/LL_ symbols`.
  final String detail;

  /// Probe weight in [0,1]; the combiner uses the max, corroboration
  /// nudges upward, conflicts cap at 0.5.
  final double weight;

  Map<String, dynamic> toJson() => {
        'signal': signal.name,
        'detail': detail,
        'weight': weight,
      };

  factory ChipEvidence.fromJson(Map<String, dynamic> json) => ChipEvidence(
        signal: ChipSignal.values.firstWhere(
          (s) => s.name == json['signal'],
          orElse: () => ChipSignal.filename,
        ),
        detail: json['detail'] as String? ?? '',
        weight: (json['weight'] as num?)?.toDouble() ?? 0,
      );
}

/// Vendor/family/part identity with provenance.
///
/// Persisted on the project as `Emulator.metadata['chip_identity']` —
/// identity is a project property; the corpus cache it unlocks is
/// shared across projects, keyed by [corpusKey].
class ChipIdentity {
  const ChipIdentity({
    this.vendor,
    this.family,
    this.part,
    this.core,
    this.svdUrl,
    this.confidence = 0,
    this.evidence = const [],
    this.userOverridden = false,
  });

  /// Canonical lowercase vendor id — the adapter-registry key
  /// ('st', 'nordic', …). Null when no probe produced a vendor.
  final String? vendor;

  /// Lowercase family id: 'stm32wb0', 'nrf52'. Null = vendor-only.
  final String? family;

  /// Display-cased part number: 'STM32WB05', 'nRF52840'.
  final String? part;

  /// Core from the repl's `cpuType` ('cortex-m0+'), informational.
  final String? core;

  /// SVD URL when detection found an `ApplySVD` line — a ready-made
  /// fetch source for the exact part.
  final String? svdUrl;

  /// 0..1. User overrides are 1.0; conflicting probes cap at 0.5.
  final double confidence;

  final List<ChipEvidence> evidence;

  final bool userOverridden;

  /// Family-level corpus cache key ('st.stm32wb0'). Null when vendor or
  /// family is unknown — corpus features disable gracefully on null.
  String? get corpusKey =>
      (vendor != null && family != null) ? '$vendor.$family' : null;

  /// One-line human summary for logs/cards.
  String get label => part ?? family ?? vendor ?? 'unknown';

  ChipIdentity copyWith({
    String? vendor,
    String? family,
    String? part,
    String? core,
    String? svdUrl,
    double? confidence,
    List<ChipEvidence>? evidence,
    bool? userOverridden,
  }) =>
      ChipIdentity(
        vendor: vendor ?? this.vendor,
        family: family ?? this.family,
        part: part ?? this.part,
        core: core ?? this.core,
        svdUrl: svdUrl ?? this.svdUrl,
        confidence: confidence ?? this.confidence,
        evidence: evidence ?? this.evidence,
        userOverridden: userOverridden ?? this.userOverridden,
      );

  Map<String, dynamic> toJson() => {
        if (vendor != null) 'vendor': vendor,
        if (family != null) 'family': family,
        if (part != null) 'part': part,
        if (core != null) 'core': core,
        if (svdUrl != null) 'svd_url': svdUrl,
        'confidence': confidence,
        'evidence': [for (final e in evidence) e.toJson()],
        'user_overridden': userOverridden,
      };

  factory ChipIdentity.fromJson(Map<String, dynamic> json) => ChipIdentity(
        vendor: json['vendor'] as String?,
        family: json['family'] as String?,
        part: json['part'] as String?,
        core: json['core'] as String?,
        svdUrl: json['svd_url'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        evidence: [
          for (final e in (json['evidence'] as List<dynamic>? ?? const []))
            ChipEvidence.fromJson(e as Map<String, dynamic>)
        ],
        userOverridden: json['user_overridden'] as bool? ?? false,
      );

  /// Key under which the identity lives in `Emulator.metadata`.
  static const metadataKey = 'chip_identity';
}

/// The one part-name grammar. Parses SVD filename stems
/// (`STM32WB05`), platform-file stems (`stm32wb05_empty`,
/// `nrf52840`), and user-typed overrides into (vendor, family, part).
class ChipNameParser {
  ChipNameParser._();

  /// Parse [raw] (a filename stem or user input). Returns null when no
  /// known vendor pattern matches.
  static ChipIdentity? parse(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;

    // ST: stm32<series letters><digits...>, family = stm32 + series +
    // first digit run's leading char (st's family convention:
    // stm32wb0 covers wb05/wb06/wb09; stm32f4 covers f401/f429...).
    final st = RegExp(r'stm32([a-z]{1,2})(\d+)').firstMatch(s);
    if (st != null) {
      final series = st.group(1)!;
      final digits = st.group(2)!;
      final family = 'stm32$series${digits[0]}';
      return ChipIdentity(
        vendor: 'st',
        family: family,
        part: 'STM32${series.toUpperCase()}$digits',
      );
    }

    // Nordic: nrf51/52/53/91 + optional part digits.
    final nrf = RegExp(r'nrf(51|52|53|91)(\d*)').firstMatch(s);
    if (nrf != null) {
      final series = nrf.group(1)!;
      final rest = nrf.group(2)!;
      return ChipIdentity(
        vendor: 'nordic',
        family: 'nrf$series',
        part: rest.isEmpty ? null : 'nRF$series$rest',
      );
    }

    return null;
  }
}
