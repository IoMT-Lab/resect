import 'dart:convert';
import 'dart:io';

import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/orchestrator/manifest_builder.dart';
import 'package:emulator_orchestrator/services/analysis/autotune_session_loader.dart';
import 'package:test/test.dart';

/// Disk reload of a persisted auto-tune session: newest-session pick,
/// round ordering, runId join to project snapshots, tolerance of
/// corrupt files and old manifests without the new metric fields.
void main() {
  late Directory projectDir;

  setUp(() {
    projectDir = Directory.systemTemp.createTempSync('session_loader_test');
  });

  tearDown(() {
    projectDir.deleteSync(recursive: true);
  });

  SynthesisManifest manifest(String runId) => buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: runId,
        success: true,
        totalIterations: 1,
        duration: const Duration(seconds: 1),
        failedSymbol: null,
        attempts: const {},
      );

  Directory sessionDir(String name) =>
      Directory('${projectDir.path}/autotune_reports/$name')
        ..createSync(recursive: true);

  void writeRound(Directory dir, int round, SynthesisManifest m) =>
      File('${dir.path}/round_${round.toString().padLeft(2, '0')}'
              '_manifest.json')
          .writeAsStringSync(jsonEncode(m.toJson()));

  test('latestSessionDir picks the newest timestamp dir', () {
    sessionDir('2026-08-18T10-00-00.000');
    final newest = sessionDir('2026-08-19T09-00-00.000');
    expect(latestAutoTuneSessionDir(projectDir.path)!.path, newest.path);
  });

  test('latestSessionDir is null without autotune_reports', () {
    expect(latestAutoTuneSessionDir(projectDir.path), isNull);
  });

  test('loads rounds in order and joins snapshots by runId', () {
    final dir = sessionDir('2026-08-19T09-00-00.000');
    // Written out of order on purpose.
    writeRound(dir, 1, manifest('run-1'));
    writeRound(dir, 0, manifest('run-0'));
    final snapshots = [
      RoundSnapshot(
        snapshotVersion: RoundSnapshot.currentVersion,
        round: 1,
        synthesizerRunId: 'run-1',
        createdAt: DateTime.utc(2026),
        hookOverrides: const {},
        hookOverrideScopes: const {},
        hookPreferences: const {},
        hookBindings: const {},
        iterationCap: 10,
        metrics: const ManifestMetrics(
          overallFidelity: 0.5,
          coverageFidelity: null,
          subgraphFidelity: null,
          intactCount: 1,
          degradedCount: 0,
          hookedCount: 0,
        ),
        executedSymbols: const ['A'],
        manifestRef: const SynthesisManifestRef(runId: 'run-1'),
        reverted: true,
      ),
    ];
    final session = loadAutoTuneSession(dir, snapshots: snapshots)!;
    expect(session.rounds.map((r) => r.round), [0, 1]);
    expect(session.rounds[0].manifest.synthesizerRunId, 'run-0');
    // Round 0 has no matching snapshot; round 1 joined by runId and
    // carries its reverted flag through.
    expect(session.rounds[0].snapshot, isNull);
    expect(session.rounds[1].snapshot!.reverted, isTrue);
  });

  test('skips corrupt round files, keeps the rest', () {
    final dir = sessionDir('2026-08-19T09-00-00.000');
    writeRound(dir, 0, manifest('run-0'));
    File('${dir.path}/round_01_manifest.json')
        .writeAsStringSync('{ not json');
    final session = loadAutoTuneSession(dir)!;
    expect(session.rounds.map((r) => r.round), [0]);
  });

  test('a dir with no readable manifests loads as null', () {
    final dir = sessionDir('2026-08-19T09-00-00.000');
    File('${dir.path}/summary.md').writeAsStringSync('# summary');
    expect(loadAutoTuneSession(dir), isNull);
  });

  test('old manifests without the new metric fields load with nulls', () {
    final dir = sessionDir('2026-08-19T09-00-00.000');
    writeRound(dir, 0, manifest('run-0'));
    final round = loadAutoTuneSession(dir)!.rounds.single;
    expect(round.manifest.stops, isNull);
    expect(round.manifest.phaseTimings, isNull);
    expect(round.manifest.census, isNull);
    expect(round.snapshot, isNull);
  });
}
