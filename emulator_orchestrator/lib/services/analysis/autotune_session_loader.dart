import 'dart:convert';
import 'dart:io';

import '../../data/models/round_snapshot.dart';
import '../../data/models/synthesis_manifest.dart';

/// One round of a persisted auto-tune session: the manifest read back
/// from `round_NN_manifest.json` (metrics, stops, phase timings, census
/// — the complete record since the engine folds round telemetry in),
/// joined when possible with the project's inline [RoundSnapshot]
/// (which carries the LLM recommendations/decisions the manifest
/// doesn't).
class AutoTuneSessionRound {
  const AutoTuneSessionRound({
    required this.round,
    required this.manifest,
    this.snapshot,
  });

  final int round;
  final SynthesisManifest manifest;

  /// Null when the snapshot was FIFO-pruned by `roundSnapshotCap`, the
  /// session was run headlessly against a different project file, or
  /// the runIds simply don't match.
  final RoundSnapshot? snapshot;
}

/// A persisted auto-tune session read back from a report directory.
class AutoTuneSession {
  const AutoTuneSession({required this.dir, required this.rounds});

  final Directory dir;

  /// Ordered by round number (0 = baseline).
  final List<AutoTuneSessionRound> rounds;
}

final _manifestNameRe = RegExp(r'^round_(\d+)_manifest\.json$');

/// The newest session directory under `<projectDir>/autotune_reports/`,
/// or null when none exists. Session dirs are named with the ISO-8601
/// start timestamp (`:` replaced by `-`), so lexicographic order is
/// chronological.
Directory? latestAutoTuneSessionDir(String projectDir) {
  final root = Directory('$projectDir/autotune_reports');
  if (!root.existsSync()) return null;
  final dirs = root.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return dirs.isEmpty ? null : dirs.last;
}

/// Load a session's rounds from [dir]'s `round_NN_manifest.json` files,
/// joining each manifest to the matching snapshot in [snapshots] by
/// `synthesizerRunId`. Unreadable/corrupt files are skipped (a partial
/// session still loads); returns null when the directory holds no
/// readable round manifests at all.
AutoTuneSession? loadAutoTuneSession(
  Directory dir, {
  List<RoundSnapshot> snapshots = const [],
}) {
  if (!dir.existsSync()) return null;
  final byRunId = {
    for (final s in snapshots) s.manifestRef.runId: s,
  };
  final rounds = <AutoTuneSessionRound>[];
  for (final entry in dir.listSync().whereType<File>()) {
    final name = entry.uri.pathSegments.last;
    final m = _manifestNameRe.firstMatch(name);
    if (m == null) continue;
    try {
      final manifest = SynthesisManifest.fromJson(
          jsonDecode(entry.readAsStringSync()) as Map<String, dynamic>);
      rounds.add(AutoTuneSessionRound(
        round: int.parse(m.group(1)!),
        manifest: manifest,
        snapshot: byRunId[manifest.synthesizerRunId],
      ));
    } catch (_) {
      // Corrupt or half-written round file — skip it, keep the rest.
    }
  }
  if (rounds.isEmpty) return null;
  rounds.sort((a, b) => a.round.compareTo(b.round));
  return AutoTuneSession(dir: dir, rounds: List.unmodifiable(rounds));
}
