import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../data/models/chip_identity.dart';

/// Fingerprint of one Renode platform description: enough of a .repl's
/// shape to recognize "this project's platform looks like nrf52840".
class PlatformFingerprint {
  const PlatformFingerprint({
    required this.stem,
    required this.cpuType,
    required this.regions,
    required this.vendorTokens,
  });

  /// Filename stem — for bundled platforms this is the part number
  /// ('nrf52840', 'stm32h743').
  final String stem;

  /// The repl's `cpuType: "cortex-m4"` value, lowercase, or ''.
  final String cpuType;

  /// Mapped memory regions as (base, size) pairs, sorted by base.
  final List<(int, int)> regions;

  /// Vendor-branded peripheral type tokens found in the file
  /// ('STM32F4_RCC', 'NRF52840_UART'), uppercase.
  final Set<String> vendorTokens;

  static final _cpuTypeRe = RegExp(r'cpuType:\s*"([^"]+)"');
  // `name: Memory.MappedMemory @ sysbus 0x20000000` … `size: 0x3000`
  // (size may be on a following indented line).
  static final _regionRe = RegExp(
      r'Memory\.\w+\s*@\s*sysbus\s+(0x[0-9a-fA-F]+)[\s\S]{0,120}?size:\s*(0x[0-9a-fA-F]+)');
  // Peripheral registration type names carrying a vendor brand:
  // `uart0: UART.NRF52840_UART @ …`, `rcc: Miscellaneous.STM32F4_RCC @ …`.
  static final _brandedTypeRe =
      RegExp(r':\s*[A-Za-z]+\.((?:STM32|NRF5\d|NRF9\d)[A-Za-z0-9_]*)');

  factory PlatformFingerprint.parse(String stem, String replContent) {
    final cpu = _cpuTypeRe.firstMatch(replContent)?.group(1) ?? '';
    final regions = <(int, int)>[
      for (final m in _regionRe.allMatches(replContent))
        (int.parse(m.group(1)!), int.parse(m.group(2)!)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final tokens = {
      for (final m in _brandedTypeRe.allMatches(replContent))
        m.group(1)!.toUpperCase(),
    };
    return PlatformFingerprint(
      stem: stem,
      cpuType: cpu.toLowerCase(),
      regions: regions,
      vendorTokens: tokens,
    );
  }

  Map<String, dynamic> toJson() => {
        'stem': stem,
        'cpu': cpuType,
        'regions': [
          for (final r in regions) [r.$1, r.$2]
        ],
        'tokens': vendorTokens.toList(),
      };

  factory PlatformFingerprint.fromJson(Map<String, dynamic> json) =>
      PlatformFingerprint(
        stem: json['stem'] as String,
        cpuType: json['cpu'] as String? ?? '',
        regions: [
          for (final r in (json['regions'] as List<dynamic>? ?? const []))
            ((r as List)[0] as int, r[1] as int)
        ],
        vendorTokens: {
          for (final t in (json['tokens'] as List<dynamic>? ?? const []))
            t as String
        },
      );
}

/// A ranked match of the project platform against a bundled one.
class PlatformMatch {
  const PlatformMatch({required this.identity, required this.score, required this.stem});
  final ChipIdentity identity;

  /// 0..1: fraction of the project's regions matched, gated on cpuType.
  final double score;
  final String stem;
}

/// Index over the Renode-bundled part-named platform files
/// (`emulation_engine/renode_*/platforms/{cpus,boards}/*.repl`) —
/// a free reverse-lookup from platform shape to part number.
///
/// Scanning ~180 small files takes tens of ms; the result is cached as
/// JSON keyed by the platforms directory path+mtime so repeated app
/// launches don't re-read them.
class PlatformIndex {
  PlatformIndex(this.fingerprints);

  final List<PlatformFingerprint> fingerprints;

  /// Build from an engine directory (the parent containing one or more
  /// `renode_*-portable/platforms` trees). [cacheFile] (optional)
  /// persists the scan.
  static Future<PlatformIndex> load({
    required Directory engineDir,
    File? cacheFile,
  }) async {
    final platformDirs = <Directory>[];
    if (await engineDir.exists()) {
      await for (final e in engineDir.list()) {
        if (e is Directory) {
          for (final sub in ['platforms/cpus', 'platforms/boards']) {
            final d = Directory(p.join(e.path, sub));
            if (await d.exists()) platformDirs.add(d);
          }
        }
      }
    }

    // Cache key: concatenated dir paths + max mtime.
    var newestMs = 0;
    for (final d in platformDirs) {
      final stat = await d.stat();
      final ms = stat.modified.millisecondsSinceEpoch;
      if (ms > newestMs) newestMs = ms;
    }
    final cacheKey = '${platformDirs.map((d) => d.path).join(';')}|$newestMs';

    if (cacheFile != null && await cacheFile.exists()) {
      try {
        final json =
            jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
        if (json['key'] == cacheKey) {
          return PlatformIndex([
            for (final f in (json['fingerprints'] as List<dynamic>))
              PlatformFingerprint.fromJson(f as Map<String, dynamic>)
          ]);
        }
      } catch (_) {
        // Corrupt cache — rescan.
      }
    }

    final fingerprints = <PlatformFingerprint>[];
    for (final dir in platformDirs) {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.repl')) continue;
        try {
          fingerprints.add(PlatformFingerprint.parse(
            p.basenameWithoutExtension(f.path),
            await f.readAsString(),
          ));
        } catch (_) {
          // Unreadable platform file — skip.
        }
      }
    }

    if (cacheFile != null) {
      try {
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsString(jsonEncode({
          'key': cacheKey,
          'fingerprints': [for (final f in fingerprints) f.toJson()],
        }));
      } catch (_) {
        // Cache write is best-effort.
      }
    }
    return PlatformIndex(fingerprints);
  }

  /// Match a project's platform content against the bundled set.
  /// Candidates must share `cpuType` and at least one exact
  /// (base, size) memory region; ranked by matched-region fraction.
  /// Only stems that parse to a known vendor are returned.
  List<PlatformMatch> match(String replContent) {
    final probe = PlatformFingerprint.parse('probe', replContent);
    if (probe.regions.isEmpty && probe.cpuType.isEmpty) return const [];

    final matches = <PlatformMatch>[];
    for (final f in fingerprints) {
      if (probe.cpuType.isNotEmpty &&
          f.cpuType.isNotEmpty &&
          probe.cpuType != f.cpuType) {
        continue;
      }
      final shared = probe.regions.where(f.regions.contains).length;
      if (shared == 0) continue;
      final identity = ChipNameParser.parse(f.stem);
      if (identity == null) continue;
      matches.add(PlatformMatch(
        identity: identity,
        score: shared / probe.regions.length,
        stem: f.stem,
      ));
    }
    matches.sort((a, b) => b.score.compareTo(a.score));
    return matches;
  }
}
