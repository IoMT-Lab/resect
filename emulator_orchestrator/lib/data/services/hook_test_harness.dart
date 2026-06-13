import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:renode/renode.dart';

import '../../config/env_config.dart';
import '../../core/app_paths.dart';
import 'test_harness_assets.dart';

/// Result of running a single hook against the minimal test firmware.
class HookTestResult {
  /// 10 uint32 values from `results[]`. Element [i] is whatever the hook
  /// returned on the i-th invocation of `main()`. Empty when the test
  /// errored before reading memory.
  final List<int> returnValues;

  /// True when the bootstrap reached `halt_loop` cleanly within the
  /// timeout. False when something went wrong (timeout, Renode crash,
  /// unhandled access, hook syntax error, etc.).
  final bool ranToCompletion;

  /// Human-readable error message when [ranToCompletion] is false.
  final String? errorMessage;

  /// Wall-clock time the test took.
  final Duration runtime;

  /// Tail of Renode's stdout+stderr captured during the run. Empty
  /// when the log file couldn't be read. Hook bodies that
  /// `print(...)` or `sys.stderr.write(...)` show up here.
  final String renodeLogTail;

  const HookTestResult({
    required this.returnValues,
    required this.ranToCompletion,
    required this.errorMessage,
    required this.runtime,
    required this.renodeLogTail,
  });
}

/// Runs hooks against the bundled minimal Cortex-M4 firmware in a
/// fresh Renode machine isolated from the user's project. Stateless
/// across calls — every invocation spawns a brand-new Renode process
/// on a private port, loads the bundled platform + ELF, applies the
/// hook to `main`, runs, reads results, and tears down.
///
/// Serializes concurrent invocations so a single hardcoded port is
/// safe even if the UI accidentally fires two tests in quick
/// succession.
class HookTestHarness {
  /// Renode port the harness uses. Hardcoded and intentionally NOT
  /// configurable from `resect.config` — we don't want the harness
  /// to ever collide with the user's main emulation port (which IS
  /// config-driven via `RENODE_PORT`).
  static const _port = 5099;

  /// Serialize concurrent invocations. The UI button is one-at-a-time
  /// but the orchestrator API may grow other callers.
  Completer<void>? _inflight;

  /// Default Renode scope passed to `AddHookAtSymbol` when the caller
  /// doesn't supply one. Required for stateful hooks (`readHook`,
  /// `writeHook`, `incrementHook`) to share Python `globals()` state
  /// across the 10 `main()` invocations the bootstrap performs — a
  /// null/missing scope makes Renode start a fresh interpreter for
  /// each call, so `incrementVariable`'s state never accumulates and
  /// every call sees the variable as missing, reinitializes it, and
  /// increments to `default+1`.
  ///
  /// The real project gets this for free because the user sets a
  /// scope per-override in the call-graph metadata sidebar (plan C2).
  /// The harness has no per-override UI, so it bakes in a fixed
  /// scope to make stateful hooks observably stateful out of the box.
  static const _defaultScope = 'hook_test';

  Future<HookTestResult> runHook({
    required String hookCode,
    String? scope,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Serialize: queue behind any in-flight test.
    while (_inflight != null) {
      try {
        await _inflight!.future;
      } catch (_) {
        // Prior run failed — that's fine, we get our turn next.
      }
    }
    final myCompleter = Completer<void>();
    _inflight = myCompleter;
    try {
      final result = await _runOne(
        hookCode: hookCode,
        scope: scope,
        timeout: timeout,
      );
      return result;
    } finally {
      _inflight = null;
      myCompleter.complete();
    }
  }

  Future<HookTestResult> _runOne({
    required String hookCode,
    required String? scope,
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    final cfg = EnvConfig.load();
    final renodeBin = _resolveRenodeBin(cfg);
    const logDir = '/tmp/resect_hook_test_harness';
    await Directory(logDir).create(recursive: true);
    final logSink = File('$logDir/renode.log').openWrite();
    logSink.done.ignore();

    await _freeStalePort(_port);

    final process = RenodeProcess(renodeBin, _port, logSink, logSink);
    RenodeClient? client;
    StreamSubscription<UnhandledAccessEvent>? unhandledSub;

    String? errorMessage;
    var ranToCompletion = false;
    var returnValues = <int>[];

    try {
      await process.start();
      client = await RenodeClient.connect(
        'localhost',
        _port,
        retryCount: 60,
        retryDelay: const Duration(milliseconds: 250),
      );

      // Load the bundled platform + firmware. createMachine takes the
      // .repl as base64; loadFirmware takes the .elf as base64. Both
      // are pre-encoded in test_harness_assets.dart so no filesystem
      // round-trip is needed.
      final replBytes = base64Decode(testHarnessReplBase64);
      final elfBytes = base64Decode(testHarnessElfBase64);
      await client.createMachine(Base64Data.fromBytes(replBytes));
      await client.loadFirmware(Base64Data.fromBytes(elfBytes));

      // Apply the hook to `main`. We deliberately do NOT use
      // `client.addHook` here — that path emits the inline-quoted
      // form `sysbus AddHookAtSymbol "sym" "code" "scope"`, and when
      // the catalog's hook bodies (multi-line Python with literal
      // newlines) get spliced into the second `"..."`, Renode's
      // monitor parser closes the string at the first newline and
      // treats the scope arg as orphaned tokens — silently dropping
      // it. Production (`DartEmulationController._applyHooks`) avoids
      // this by using a two-step variable-reference form:
      //   set hookvar
      //   """<body>"""
      //   sysbus AddHookAtSymbol "sym" $hookvar "scope"
      // The triple-quote `set` stashes the body in a monitor variable
      // that survives across newlines; AddHookAtSymbol references it
      // as $hookvar so its 3rd-arg scope is parsed cleanly.
      const hookVar = 'resect_test_hook';
      final effectiveScope =
          (scope == null || scope.isEmpty) ? _defaultScope : scope;
      stderr.writeln(
          '[HookTestHarness] adding hook on `$testHarnessMainSymbol` '
          'with scope="$effectiveScope" (code=${hookCode.length}B)');
      final hookSetCmd = 'set $hookVar \n"""\n$hookCode\n"""';
      final hookApplyCmd = 'sysbus AddHookAtSymbol '
          '"$testHarnessMainSymbol" \$$hookVar "$effectiveScope"';
      await client.callMany([hookSetCmd, hookApplyCmd]);

      // Watch for unhandled accesses — a hook syntax error or a runaway
      // bootstrap will surface here before the timeout fires.
      final unhandledMessages = <String>[];
      unhandledSub = client.onUnhandledAccess.listen((event) {
        unhandledMessages.add(
          'unhandled ${event.isWrite ? "write" : "read"} '
          'at PC=${event.programCounter.toRadixString(16)} '
          'in symbol ${event.name}',
        );
      });

      // Subscribe to state changes BEFORE calling run() so we don't
      // miss the pause event for fast tests.
      final paused = client.onStateChanged
          .firstWhere((e) => e.state == State.paused)
          .timeout(timeout);

      // Run; pause when PC reaches `halt_loop` (bootstrap finished).
      await client.run(
        endAt: [testHarnessHaltSymbol],
        pauseOnUnhandled: true,
      );

      await paused;

      // Read the 10-entry uint32 results array.
      final rawResultsB64 = await client.readMemory(
        testHarnessResultsAddr,
        testHarnessResultsCount * 4,
      );
      final rawBytes = base64Decode(rawResultsB64.to<String>());
      returnValues = _decodeUint32Le(rawBytes);

      // If we got here, the bootstrap reached halt_loop. If an
      // unhandled access fired *during* the run, surface it as a
      // soft warning but keep the results we read.
      if (unhandledMessages.isNotEmpty) {
        errorMessage = 'Bootstrap completed but unhandled access(es) '
            'occurred during the run:\n  ${unhandledMessages.join("\n  ")}';
        ranToCompletion = true; // still completed; warning only
      } else {
        ranToCompletion = true;
      }
    } on TimeoutException {
      errorMessage = 'Test timed out after ${timeout.inSeconds}s. '
          'The bootstrap never reached `halt_loop` — usually means '
          'the hook crashed, returned without setting PC = LR, or '
          'has a syntax error. Check the Renode log at '
          '$logDir/renode.log for details.';
    } catch (e, st) {
      errorMessage = 'Test errored: $e\n$st';
    } finally {
      await unhandledSub?.cancel();
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

    // After the sink is flushed + closed, read the last ~80 lines of
    // the log file. Hook bodies that `print(...)` or
    // `sys.stderr.write(...)` land here; surfacing the tail in the
    // result dialog means callers don't have to `cat` to debug.
    final renodeLogTail = _readLogTail('$logDir/renode.log', maxLines: 80);

    return HookTestResult(
      returnValues: returnValues,
      ranToCompletion: ranToCompletion,
      errorMessage: errorMessage,
      runtime: stopwatch.elapsed,
      renodeLogTail: renodeLogTail,
    );
  }

  /// Read the last [maxLines] lines of [path]. Returns empty on any
  /// failure (file missing, permission denied, etc.) — the log is a
  /// diagnostic nicety, not load-bearing.
  String _readLogTail(String path, {int maxLines = 80}) {
    try {
      final lines = File(path).readAsLinesSync();
      final from = lines.length > maxLines ? lines.length - maxLines : 0;
      return lines.sublist(from).join('\n');
    } catch (_) {
      return '';
    }
  }

  static List<int> _decodeUint32Le(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    final out = <int>[];
    for (var i = 0; i + 4 <= view.lengthInBytes; i += 4) {
      out.add(view.getUint32(i, Endian.little));
    }
    return out;
  }

  /// Pick the newest patched Renode portable available under
  /// `emulation_engine/`. The harness deliberately diverges from
  /// `DartEngine._resolveRenodeBin`'s config-driven choice — the
  /// scope-arg support that stateful hooks depend on is a bespoke
  /// patch with newer revisions sometimes fixing bugs in older
  /// revisions, and the harness should always test against the most
  /// capable build the user has on disk, regardless of what their
  /// main UI is pinned to.
  ///
  /// Resolution order:
  ///   1. `RENODE_BIN` (config or env) — absolute path override.
  ///   2. Newest `renode_1.16.1+*-portable/renode` under the engine
  ///      directory. "Newest" = lexicographically largest name, which
  ///      matches the `+YYYYMMDDgit...` date suffix the portables
  ///      use.
  ///   3. `RENODE_PORTABLE` config / env fallback.
  ///   4. Hardcoded stock `renode_1.16.0-dotnet_portable`.
  String _resolveRenodeBin(EnvConfig cfg) {
    final configured = cfg.get('RENODE_BIN') ?? Platform.environment['RENODE_BIN'];
    if (configured != null && configured.isNotEmpty) return configured;
    final dir = cfg.get('ENGINE_DIR') ?? AppPaths.findEngineDir();
    final newest = _newestPatchedPortable(dir);
    if (newest != null) {
      stderr.writeln(
          '[HookTestHarness] using newest patched portable: $newest');
      return '$dir/$newest/renode';
    }
    final portable = cfg.get('RENODE_PORTABLE') ??
        Platform.environment['RENODE_PORTABLE'] ??
        'renode_1.16.0-dotnet_portable';
    stderr.writeln(
        '[HookTestHarness] no patched portable found, falling back to '
        '$portable');
    return '$dir/$portable/renode';
  }

  /// Scan [engineDir] for `renode_1.16.1+*-portable` directories that
  /// contain a `renode` binary. Returns the lexicographically largest
  /// (newest date suffix) or null if none found.
  String? _newestPatchedPortable(String engineDir) {
    try {
      final entries = Directory(engineDir).listSync();
      final candidates = entries
          .whereType<Directory>()
          .map((d) => d.path.split('/').last)
          .where((n) => n.startsWith('renode_1.16.1+') &&
              n.endsWith('-portable'))
          .where((n) => File('$engineDir/$n/renode').existsSync())
          .toList()
        ..sort();
      return candidates.isEmpty ? null : candidates.last;
    } catch (_) {
      return null;
    }
  }

  /// Reclaim the harness port if a prior crash left a Renode listening
  /// on it. Same shape as `DartEngine._freeStalePort`.
  Future<void> _freeStalePort(int port) async {
    try {
      final result =
          await Process.run('lsof', ['-t', '-i:$port', '-sTCP:LISTEN']);
      final pids = (result.stdout as String)
          .split('\n')
          .where((s) => s.trim().isNotEmpty);
      for (final pid in pids) {
        stderr.writeln('[HookTestHarness] freeing stale process $pid on port $port');
        Process.killPid(int.parse(pid.trim()), ProcessSignal.sigterm);
      }
    } catch (_) {
      // lsof absent or nothing listening — nothing to free.
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }
}
