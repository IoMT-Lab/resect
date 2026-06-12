/// Behavioural quality signal (Layer 2 of the metric, weight 0.6).
/// Runs the user's actual project firmware in a fresh Renode
/// process twice — once with the candidate hook installed at the
/// target symbol, once without — and compares how far the firmware
/// progresses in each.
///
/// "Progress" is measured as instructions executed in a bounded
/// time window, read via the `cpu ExecutedInstructions` Monitor
/// command. A hook that unblocks the firmware to make meaningful
/// progress beyond the baseline scores higher; one that doesn't,
/// scores near zero.
///
/// Distinct from `HookTestHarness` (which uses a BUNDLED minimal
/// rig to test substitute-pattern correctness in isolation). This
/// runner uses the USER'S project `.repl` + ELF — the same
/// environment they actually emulate with. The two are
/// complementary: harness catches "the hook misbehaves at all",
/// progress runner catches "the hook lets the firmware advance".
///
/// Slow: each measurement boots Renode twice, each boot ~3-5 s
/// plus the configured run window. Caller should run this
/// asynchronously after the gate passes (same pattern as the
/// LLM judge).
library;

import 'dart:async';
import 'dart:io';

import 'package:hooks/hooks.dart' show includeSystemModules, substituteImport;
import 'package:renode/renode.dart';

import '../../config/env_config.dart';
import '../../core/app_paths.dart';

/// Outcome of one progress measurement. Includes the raw
/// instruction counts so the dialog can surface them in the
/// breakdown, and the normalised 0-1 score.
class HookProgressResult {
  const HookProgressResult({
    required this.withHookInstructions,
    required this.baselineInstructions,
    required this.score,
    required this.elapsed,
    this.errorMessage,
  });

  final int withHookInstructions;
  final int baselineInstructions;
  final double score; // 0.0 - 1.0
  final Duration elapsed;

  /// Non-null when one or both runs failed to produce a usable
  /// count (Renode unreachable, .repl parse error, etc.). The
  /// score is 0 in that case.
  final String? errorMessage;
}

/// Runs the user's project firmware in a fresh Renode process.
/// Stateless across calls; serialises concurrent invocations to
/// keep the hardcoded port collision-free.
class HookProgressRunner {
  /// Port used by the progress runner. Hardcoded and distinct from
  /// [HookTestHarness]'s 5099 so the two can run back-to-back
  /// without a teardown wait. Picked above the typical ephemeral
  /// range (which on Linux starts at 32768 and includes 49152+
  /// per IANA) to reduce TIME_WAIT collision with random outgoing
  /// connections; Renode's "specified port unavailable" failure
  /// mode was observed at 5098 on the dev machine.
  static const _port = 5198;

  Completer<void>? _inflight;

  /// Measure progress with/without the hook. Both runs use the
  /// same project files. The hook is installed via
  /// `AddHookAtSymbol` at [targetSymbol] for the with-hook run;
  /// the baseline run has no hook applied.
  ///
  /// [runWindow] caps each emulation pass. Default 3 s — enough
  /// for the firmware to make meaningful progress past startup,
  /// short enough that a measurement doesn't take minutes.
  /// [referenceWindow] is the instruction-count delta that maps
  /// to a score of 1.0 (larger delta clamps to 1.0; smaller
  /// scales linearly).
  Future<HookProgressResult> measure({
    required String replPath,
    required String elfPath,
    required String targetSymbol,
    required String hookCode,
    String? scope,
    Duration runWindow = const Duration(seconds: 3),
    int referenceWindow = 1000000, // 1M instructions delta = score 1.0
  }) async {
    while (_inflight != null) {
      try {
        await _inflight!.future;
      } catch (_) {
        /* prior run errored; our turn now */
      }
    }
    final completer = Completer<void>();
    _inflight = completer;
    final stopwatch = Stopwatch()..start();
    try {
      // Materialise the hook body once (substituteImport inlines
      // the hooks-dart helpers like `set_return_value`).
      includeSystemModules();
      final substituted = substituteImport(hookCode);

      String? error;
      var withCount = 0;
      var baselineCount = 0;
      try {
        withCount = await _runOnePass(
          replPath: replPath,
          elfPath: elfPath,
          targetSymbol: targetSymbol,
          hookCode: substituted,
          scope: scope,
          runWindow: runWindow,
        );
      } catch (e) {
        error = 'with-hook run failed: $e';
      }
      if (error == null) {
        try {
          baselineCount = await _runOnePass(
            replPath: replPath,
            elfPath: elfPath,
            targetSymbol: targetSymbol,
            hookCode: null,
            scope: scope,
            runWindow: runWindow,
          );
        } catch (e) {
          error = 'baseline run failed: $e';
        }
      }

      final delta = withCount - baselineCount;
      final score =
          (delta <= 0) ? 0.0 : (delta / referenceWindow).clamp(0.0, 1.0);

      return HookProgressResult(
        withHookInstructions: withCount,
        baselineInstructions: baselineCount,
        score: score,
        elapsed: stopwatch.elapsed,
        errorMessage: error,
      );
    } finally {
      _inflight = null;
      completer.complete();
    }
  }

  /// One Renode boot → load → optional-hook → run-for-T → read
  /// ExecutedInstructions → tear down. Returns the instruction
  /// count read from the CPU after the run window.
  Future<int> _runOnePass({
    required String replPath,
    required String elfPath,
    required String targetSymbol,
    required String? hookCode,
    required String? scope,
    required Duration runWindow,
  }) async {
    final cfg = EnvConfig.load();
    final renodeBin = _resolveRenodeBin(cfg);
    const logDir = '/tmp/resect_hook_progress_runner';
    await Directory(logDir).create(recursive: true);
    final logSink = File('$logDir/renode.log').openWrite();
    logSink.done.ignore();

    await _freeStalePort(_port);

    final process = RenodeProcess(renodeBin, _port, logSink, logSink);
    RenodeClient? client;

    try {
      await process.start();
      client = await RenodeClient.connect(
        'localhost',
        _port,
        retryCount: 60,
        retryDelay: const Duration(milliseconds: 250),
      );

      final replBytes = await File(replPath).readAsBytes();
      final elfBytes = await File(elfPath).readAsBytes();
      await client.createMachine(Base64Data.fromBytes(replBytes));
      await client.loadFirmware(Base64Data.fromBytes(elfBytes));

      if (hookCode != null) {
        const hookVar = 'resect_progress_hook';
        final effectiveScope =
            (scope == null || scope.isEmpty) ? 'progress' : scope;
        await client.callMany([
          'set $hookVar \n"""\n$hookCode\n"""',
          'sysbus AddHookAtSymbol "$targetSymbol" \$$hookVar "$effectiveScope"',
        ]);
      }

      // Start emulation, wait runWindow, pause, read counter.
      await client.callMany(['start']);
      await Future<void>.delayed(runWindow);
      await client.callMany(['pause']);

      // `cpu ExecutedInstructions` returns the count as a
      // hex-prefixed string (verified against Renode 1.16:
      // "(machine-0) cpu ExecutedInstructions\r\n\r0x0000…\r\r\n").
      final response = await client.call('cpu ExecutedInstructions');
      return _parseInstructionCount(response);
    } finally {
      try {
        await client?.dispose();
      } catch (_) {}
      try {
        await process.stop();
      } catch (_) {}
      try {
        await logSink.flush();
        await logSink.close();
      } catch (_) {}
    }
  }

  /// Parse the Monitor's response to `cpu ExecutedInstructions`.
  /// Renode 1.16 emits a response shaped like:
  ///   `(machine-0) cpu ExecutedInstructions\r\n\r0x0000000000077655\r\r\n`
  /// where the value is hex-formatted with a `0x` prefix and
  /// leading zeros. Match the hex literal first; fall back to a
  /// decimal scan for forward compatibility.
  int _parseInstructionCount(String response) {
    final hexMatch =
        RegExp(r'0x([0-9a-fA-F]+)').firstMatch(response);
    if (hexMatch != null) {
      return int.parse(hexMatch.group(1)!, radix: 16);
    }
    // Decimal fallback: skip any digits adjacent to a non-digit
    // identifier (e.g. "machine-0" produces a spurious 0).
    final decMatch = RegExp(r'(?<![A-Za-z_-])\d+').firstMatch(response);
    if (decMatch == null) {
      throw StateError(
        'Could not parse instruction count from "$response".',
      );
    }
    return int.parse(decMatch.group(0)!);
  }

  /// Same Renode-bin resolution as [HookTestHarness] — prefers the
  /// newest patched portable on disk so the scope-arg support in
  /// `AddHookAtSymbol` is available.
  String _resolveRenodeBin(EnvConfig cfg) {
    final configured =
        cfg.get('RENODE_BIN') ?? Platform.environment['RENODE_BIN'];
    if (configured != null && configured.isNotEmpty) return configured;
    final dir = cfg.get('ENGINE_DIR') ?? AppPaths.findEngineDir();
    final newest = _newestPatchedPortable(dir);
    if (newest != null) return '$dir/$newest/renode';
    final portable = cfg.get('RENODE_PORTABLE') ??
        Platform.environment['RENODE_PORTABLE'] ??
        'renode_1.16.0-dotnet_portable';
    return '$dir/$portable/renode';
  }

  String? _newestPatchedPortable(String engineDir) {
    try {
      final entries = Directory(engineDir).listSync();
      final candidates = entries
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .where((n) =>
              n.startsWith('renode_1.16.1+') && n.endsWith('-portable'))
          .where((n) => File('$engineDir/$n/renode').existsSync())
          .toList()
        ..sort();
      return candidates.isEmpty ? null : candidates.last;
    } catch (_) {
      return null;
    }
  }

  Future<void> _freeStalePort(int port) async {
    try {
      final result =
          await Process.run('lsof', ['-t', '-i:$port', '-sTCP:LISTEN']);
      final pids = (result.stdout as String)
          .split('\n')
          .where((s) => s.trim().isNotEmpty);
      for (final pid in pids) {
        Process.killPid(int.parse(pid.trim()), ProcessSignal.sigterm);
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

