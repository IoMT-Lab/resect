import '../../data/models/chip_identity.dart';

/// What a fetched item is, which drives how it's ingested.
enum CorpusItemKind {
  /// SDK source/header archive (chunked as code with provenance headers).
  sdkSource,

  /// CMSIS-SVD register description (distilled per-peripheral).
  svd,

  /// Part datasheet PDF (pdftotext → prose chunks).
  datasheetPdf,

  /// Family/part reference manual PDF.
  referenceManualPdf,
}

/// Which subtrees of an extracted archive to keep. Everything not
/// matched by a keep rule is discarded at extract time — SDK archives
/// are hundreds of MB, the useful HAL/CMSIS slice is a fraction of it.
class ExtractRule {
  const ExtractRule(this.glob, {this.optional = false});

  /// Glob over archive-relative paths, e.g.
  /// `*/Drivers/STM32WB0x_HAL_Driver/**`. A leading `*/` absorbs the
  /// tarball's top-level directory.
  final String glob;

  final bool optional;
}

/// One concrete thing to download.
class FetchItem {
  const FetchItem({
    required this.key,
    required this.url,
    required this.kind,
    required this.licenseNote,
    this.approxBytes,
    this.keep = const [],
    this.part,
    this.optional = false,
  });

  /// Stable id: 'sdk:stm32cubewb0', 'svd:STM32WB05', 'rm:rm0505'.
  final String key;

  /// Pinned URL (tag/commit) — refresh is an adapter-version event, not
  /// a moving ref.
  final Uri url;

  final CorpusItemKind kind;

  /// Curated size estimate for the consent prompt (null = unknown).
  final int? approxBytes;

  /// Shown at consent and stored with the item. The cache is strictly
  /// local; nothing is redistributed.
  final String licenseNote;

  /// Archive extract rules (empty for single-file items).
  final List<ExtractRule> keep;

  /// Part this item is specific to; null = family-wide (SDKs).
  final String? part;

  /// Optional items (PDFs) may fail without failing the fetch; they are
  /// recorded skipped with the URL surfaced for manual drop-in.
  final bool optional;

  Map<String, dynamic> toJson() => {
        'key': key,
        'url': url.toString(),
        'kind': kind.name,
        if (approxBytes != null) 'approx_bytes': approxBytes,
        'license_note': licenseNote,
        'keep': [for (final k in keep) k.glob],
        if (part != null) 'part': part,
        'optional': optional,
      };
}

/// The full, concrete plan for one chip's corpus — what the consent
/// dialog renders and what the executor runs. Pure data.
class FetchPlan {
  const FetchPlan({
    required this.corpusKey,
    required this.chip,
    required this.items,
    this.notes = const [],
  });

  final String corpusKey;
  final ChipIdentity chip;
  final List<FetchItem> items;

  /// Honest caveats surfaced to the user ('no curated datasheet for
  /// STM32WB06 — drop a PDF into drop_in/ to include one').
  final List<String> notes;

  int get approxTotalBytes =>
      items.fold(0, (sum, i) => sum + (i.approxBytes ?? 0));

  Map<String, dynamic> toJson() => {
        'corpus_key': corpusKey,
        'chip': chip.toJson(),
        'items': [for (final i in items) i.toJson()],
        'notes': notes,
      };
}

/// A curated per-vendor source of SDKs and documents.
///
/// [plan] is a PURE function over static curated tables — no network —
/// so plans are golden-file testable offline, and the CLI confirmation
/// and the UI consent dialog render from the same object the executor
/// consumes. Adding a vendor = one adapter file + one registry line.
abstract class VendorCorpusAdapter {
  const VendorCorpusAdapter();

  /// Canonical vendor id, matching `ChipIdentity.vendor`.
  String get id;

  /// Bumped whenever curated tables change; cached items fetched under
  /// an older version read as stale in status.
  int get version;

  /// Symbol prefixes that fingerprint this vendor's SDKs (feeds the
  /// chip detector's vendor-inference table).
  Set<String> get symbolPrefixes;

  /// Whether this adapter has curated sources for [chip]'s family.
  bool canHandle(ChipIdentity chip);

  FetchPlan plan(ChipIdentity chip);
}
