import 'package:path/path.dart' as p;

import '../../data/models/chip_identity.dart';
import 'platform_index.dart';

/// MCU detection over the identity signals a project already carries.
///
/// [detect] is pure (no I/O): callers hand it the repl content/paths,
/// symbol names, and any [PlatformMatch]es from a [PlatformIndex]. The
/// combiner merges probe results highest-weight-wins per field,
/// corroboration raises confidence, and a vendor conflict caps it at
/// 0.5 with both evidences kept for the UI to show.
class ChipDetector {
  ChipDetector._();

  /// Vendor inference table for firmware symbol prefixes. Vendor-level
  /// only; a probe needs [kMinPrefixHits] matching symbols to count.
  static const vendorSymbolPrefixes = <String, List<String>>{
    'st': ['HAL_', 'LL_', '__HAL_'],
    'nordic': ['nrf_', 'nrfx_', 'sd_'],
  };

  static const kMinPrefixHits = 5;

  static final _applySvdRe = RegExp(r'ApplySVD\s+@(\S+)');

  static ChipIdentity detect({
    String? replContent,
    String? replPath,
    String? elfPath,
    Iterable<String> symbolNames = const [],
    List<PlatformMatch> platformMatches = const [],
  }) {
    final probes = <ChipIdentity>[];
    final evidence = <ChipEvidence>[];

    // 1. ApplySVD URL — exact part + a fetchable register map.
    final svd = replContent == null
        ? null
        : _applySvdRe.firstMatch(replContent)?.group(1);
    if (svd != null) {
      final stem = p.basenameWithoutExtension(Uri.parse(svd).path);
      final parsed = ChipNameParser.parse(stem);
      if (parsed != null) {
        probes.add(parsed.copyWith(svdUrl: svd));
        evidence.add(ChipEvidence(
          signal: ChipSignal.svdUrl,
          detail: 'ApplySVD $svd',
          weight: 1.0,
        ));
      }
    }

    // 2. Bundled-platform fingerprint (best match only).
    if (platformMatches.isNotEmpty) {
      final best = platformMatches.first;
      probes.add(best.identity);
      evidence.add(ChipEvidence(
        signal: ChipSignal.platformFingerprint,
        detail: 'matched bundled platform ${best.stem}.repl '
            '(${(best.score * 100).round()}% region overlap)',
        weight: 0.85 * best.score,
      ));
    }

    // 3. Filename grammar over repl and ELF names.
    for (final path in [replPath, elfPath]) {
      if (path == null) continue;
      final parsed = ChipNameParser.parse(p.basenameWithoutExtension(path));
      if (parsed != null) {
        probes.add(parsed);
        evidence.add(ChipEvidence(
          signal: ChipSignal.filename,
          detail: 'filename ${p.basename(path)}',
          weight: 0.6,
        ));
      }
    }

    // 4. Symbol-prefix vendor inference (vendor only).
    String? prefixVendor;
    var prefixHits = 0;
    for (final entry in vendorSymbolPrefixes.entries) {
      final hits = symbolNames
          .where((s) => entry.value.any(s.startsWith))
          .take(1000)
          .length;
      if (hits >= kMinPrefixHits && hits > prefixHits) {
        prefixVendor = entry.key;
        prefixHits = hits;
      }
    }
    if (prefixVendor != null) {
      probes.add(ChipIdentity(vendor: prefixVendor));
      evidence.add(ChipEvidence(
        signal: ChipSignal.symbolPrefix,
        detail: '$prefixHits ${vendorSymbolPrefixes[prefixVendor]!.join('/')} '
            'symbols',
        weight: 0.4,
      ));
    }

    // Core straight from the repl.
    final core = replContent == null
        ? null
        : RegExp(r'cpuType:\s*"([^"]+)"').firstMatch(replContent)?.group(1);

    if (probes.isEmpty) {
      return ChipIdentity(core: core, confidence: 0, evidence: evidence);
    }

    // Combine: fields from the highest-weight probe that has them;
    // evidence list keeps everything.
    final ranked = List.generate(probes.length, (i) => (probes[i], evidence[i]))
      ..sort((a, b) => b.$2.weight.compareTo(a.$2.weight));
    var merged = ChipIdentity(core: core);
    for (final (probe, _) in ranked) {
      merged = merged.copyWith(
        vendor: merged.vendor ?? probe.vendor,
        family: merged.family ?? probe.family,
        part: merged.part ?? probe.part,
        svdUrl: merged.svdUrl ?? probe.svdUrl,
      );
    }

    // Confidence: top weight, +0.1 per corroborating probe agreeing on
    // vendor, capped at 0.5 when any probe DISAGREES on vendor.
    final vendors =
        probes.map((pr) => pr.vendor).whereType<String>().toSet();
    var confidence = ranked.first.$2.weight;
    if (vendors.length == 1 && probes.length > 1) {
      confidence = (confidence + 0.1 * (probes.length - 1)).clamp(0.0, 1.0);
    }
    final conflict = vendors.length > 1;
    if (conflict) confidence = confidence.clamp(0.0, 0.5);

    return merged.copyWith(confidence: confidence, evidence: evidence);
  }
}
