import 'dart:io';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/analysis/autotune_session_loader.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart'
    show artifactLabelsFor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';

/// One auto-tune round as the session views consume it: the folded
/// manifest (metrics, stops, phase timings, census) plus the project
/// snapshot when available (LLM recommendations, decisions, reverted /
/// warnings flags).
class AutoTuneSessionRoundRecord {
  const AutoTuneSessionRoundRecord({
    required this.round,
    required this.manifest,
    this.snapshot,
  });

  final int round;
  final SynthesisManifest manifest;
  final RoundSnapshot? snapshot;

  bool get reverted => snapshot?.reverted ?? false;
  List<String> get warnings => snapshot?.warnings ?? const [];
}

/// The auto-tune session the UI is showing: either the live one (fed
/// round-by-round by the sink) or the newest persisted one (hydrated
/// from `autotune_reports/` on project open).
class AutoTuneSessionState {
  const AutoTuneSessionState({
    required this.rounds,
    required this.live,
    this.stopReason,
    this.errorMessage,
    this.reportDirPath,
    this.maxRounds,
  });

  /// Ordered by round (0 = baseline).
  final List<AutoTuneSessionRoundRecord> rounds;

  /// True while the session is still running (rounds keep arriving).
  final bool live;

  /// `AutoTuneStopReason.name` once the session finished; null while
  /// live and on disk-hydrated sessions (the stop reason isn't in the
  /// round manifests).
  final String? stopReason;
  final String? errorMessage;

  /// Where the session's report files live, when known.
  final String? reportDirPath;

  /// The session's configured round budget — fixes the trajectory
  /// chart's x-axis so it doesn't rescale as rounds land. Null on
  /// disk-hydrated sessions (the budget isn't persisted).
  final int? maxRounds;

  /// The round whose overlays the session holds when finished — the
  /// highest executed count among non-reverted rounds (the engine's
  /// best-so-far rule). Null when no rounds.
  int? get bestRound {
    int? best;
    var bestExecuted = -1;
    for (final r in rounds) {
      if (r.reverted) continue;
      final executed = r.manifest.metrics?.executedCount ??
          r.manifest.executedSymbols?.length ??
          0;
      if (executed > bestExecuted) {
        bestExecuted = executed;
        best = r.round;
      }
    }
    return best;
  }

  AutoTuneSessionState copyWith({
    List<AutoTuneSessionRoundRecord>? rounds,
    bool? live,
    String? stopReason,
    String? errorMessage,
    String? reportDirPath,
    int? maxRounds,
  }) =>
      AutoTuneSessionState(
        rounds: rounds ?? this.rounds,
        live: live ?? this.live,
        stopReason: stopReason ?? this.stopReason,
        errorMessage: errorMessage ?? this.errorMessage,
        reportDirPath: reportDirPath ?? this.reportDirPath,
        maxRounds: maxRounds ?? this.maxRounds,
      );
}

class AutoTuneSessionNotifier extends StateNotifier<AutoTuneSessionState?> {
  AutoTuneSessionNotifier() : super(null);

  /// A new live session is starting — clear whatever was shown.
  void beginLive(String reportDirPath, {int? maxRounds}) {
    state = AutoTuneSessionState(
      rounds: const [],
      live: true,
      reportDirPath: reportDirPath,
      maxRounds: maxRounds,
    );
  }

  /// Append a live round (idempotent on round number: a re-emit of the
  /// same round replaces it).
  void addRound(AutoTuneSessionRoundRecord record) {
    final s = state ?? const AutoTuneSessionState(rounds: [], live: true);
    final rounds = [
      ...s.rounds.where((r) => r.round != record.round),
      record,
    ]..sort((a, b) => a.round.compareTo(b.round));
    state = s.copyWith(rounds: rounds);
  }

  void finishLive(String stopReason, {String? errorMessage}) {
    final s = state;
    if (s == null) return;
    state = AutoTuneSessionState(
      rounds: s.rounds,
      live: false,
      stopReason: stopReason,
      errorMessage: errorMessage,
      reportDirPath: s.reportDirPath,
      maxRounds: s.maxRounds,
    );
  }

  /// Hydrate from the newest persisted session under the project's
  /// `autotune_reports/`, joining manifests to the project's inline
  /// snapshots. No-op (state stays null) when the project is unsaved
  /// or has no persisted sessions. Never replaces a live session.
  void hydrateFromDisk(Emulator? emulator) {
    if (state?.live == true) return;
    final projectPath = emulator?.emulatorPath;
    if (projectPath == null) {
      state = null;
      return;
    }
    final dir =
        latestAutoTuneSessionDir(File(projectPath).parent.path);
    final session = dir == null
        ? null
        : loadAutoTuneSession(dir,
            snapshots: emulator?.roundSnapshots ?? const []);
    state = session == null
        ? null
        : AutoTuneSessionState(
            rounds: [
              for (final r in session.rounds)
                AutoTuneSessionRoundRecord(
                  round: r.round,
                  manifest: r.manifest,
                  snapshot: r.snapshot,
                ),
            ],
            live: false,
            reportDirPath: session.dir.path,
          );
  }
}

/// The auto-tune session shown by the modal and the Synthesize tab.
final autoTuneSessionProvider =
    StateNotifierProvider<AutoTuneSessionNotifier, AutoTuneSessionState?>(
        (ref) => AutoTuneSessionNotifier());

/// Artifact id → human-readable effect label ("Return 1", "Stateful
/// increment (from 0)"…), the same resolver the report writer uses —
/// so session views render descriptors, not bare #ids.
final artifactLabelsProvider = FutureProvider<Map<int, String>>(
    (ref) => artifactLabelsFor(ref.watch(artifactDatabaseProvider)));
