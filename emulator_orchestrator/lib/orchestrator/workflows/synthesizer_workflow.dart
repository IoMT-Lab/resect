import 'dart:async';

import '../../data/database/artifact_database.dart';
import '../../data/models/synthesizer_result.dart';
import '../../data/services/lifecycle_service.dart';
import '../events/synthesizer_events.dart';

/// Automated hook substitution workflow for emulator creation.
///
/// The synthesizer runs an iterative loop:
/// 1. Start emulation with pauseOnUnhandled=true
/// 2. When an unhandled access pauses execution, identify the enclosing function
/// 3. Look up available hooks for that function in the artifact DB
/// 4. Apply the next untried hook
/// 5. Reset and restart emulation with accumulated hooks
/// 6. Repeat until firmware runs cleanly or a symbol exhausts all hooks
///
/// The synthesizer uses the existing EmulationWorkflow for the initial server
/// startup, then manages subsequent reset/restart cycles directly via the
/// lifecycle service (avoiding server restarts between iterations).
class SynthesizerWorkflow {
  final LifecycleService lifecycleService;
  final ArtifactDatabase artifactDb;

  /// Event stream for progress reporting.
  final _eventController = StreamController<SynthesizerEvent>.broadcast();
  Stream<SynthesizerEvent> get events => _eventController.stream;

  /// Whether a synthesis run is currently active.
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  SynthesizerWorkflow({
    required this.lifecycleService,
    required this.artifactDb,
  });

  /// Run the synthesis loop.
  ///
  /// Prerequisites: The emulation server must already be running and connected
  /// (i.e., EmulationWorkflow.start() has been called and firmware is loaded).
  /// The synthesizer takes over from there, managing reset/hook/restart cycles.
  ///
  /// Stops immediately if any symbol exhausts all hook candidates.
  ///
  /// [elfPath]: Path to the ELF firmware file
  /// [elfHash]: SHA-256 hash of the ELF (for artifact DB lookups)
  /// [baseImagePath]: Path to the .repl platform description
  /// [startFrom]: Optional symbol to start execution from
  /// [endAt]: Optional list of symbols that trigger early exit (stop conditions)
  /// [maxIterations]: Safety limit to prevent infinite loops
  Future<SynthesizerResult> run({
    required String elfPath,
    required String elfHash,
    required String baseImagePath,
    String? startFrom,
    List<String>? endAt,
    int maxIterations = 100,
    Map<String, int> hookPreferences = const {},
    Map<String, int> hookOverrides = const {},
    Map<String, String> resolvedHooks = const {},
    String? memoryMapPath,
  }) async {
    if (_isRunning) {
      throw SynthesizerException('Synthesizer is already running');
    }

    _isRunning = true;
    final stopwatch = Stopwatch()..start();

    // Accumulated state across iterations
    final hookMap = <String, String>{};        // symbol → hookName
    final hookIndex = <String, int>{};          // symbol → current hook index
    final hookCache = <String, List<Artifact>>{}; // symbol → available hooks
    final definedHooks = <String, String>{};    // hookName → hookCode (all defined hooks)

    int iteration = 0;

    // Build symbol → hookCode map from hookMap (symbol → hookName) + definedHooks (hookName → hookCode)
    Map<String, String> buildHookCodeMap() {
      return {
        for (final entry in hookMap.entries)
          if (definedHooks.containsKey(entry.value))
            entry.key: definedHooks[entry.value]!,
      };
    }

    // Pre-seed forced overrides (unconditional substitutions)
    final overriddenSymbols = <String>{};
    for (final entry in hookOverrides.entries) {
      final artifact = await artifactDb.getArtifactById(entry.value);
      if (artifact != null) {
        final hookName = '${entry.key}_override';
        definedHooks[hookName] = artifact.artifactData;
        hookMap[entry.key] = hookName;
        overriddenSymbols.add(entry.key);
        print('[Synthesizer] Pre-seeded override for "${entry.key}" (artifact #${entry.value})');
      }
    }

    // Pre-seed previously resolved hooks (warm start / resume mode)
    // Overrides take precedence — skip symbols already overridden
    for (final entry in resolvedHooks.entries) {
      if (!overriddenSymbols.contains(entry.key)) {
        final hookName = '${entry.key}_resolved';
        definedHooks[hookName] = entry.value;
        hookMap[entry.key] = hookName;
        print('[Synthesizer] Pre-seeded resolved hook for "${entry.key}"');
      }
    }

    try {
      while (iteration < maxIterations && _isRunning) {
        iteration++;

        _eventController.add(SynthesizerIterationStarted(
          iteration: iteration,
          currentHookMap: Map.unmodifiable(hookMap),
        ));

        print('[Synthesizer] Iteration $iteration — ${hookMap.length} hooks applied');

        // Reset Renode state and reload firmware for clean CPU state.
        // This runs on every iteration (including the first) to ensure the
        // program counter is at the ELF entry point, not at a location left
        // over from emulationWorkflow.start() which may have already paused.
        await lifecycleService.reset();
        await Future.delayed(const Duration(milliseconds: 500));
        await _loadFirmwareWithRetry(baseImagePath, elfPath);

        // Apply memory map (if specified)
        if (memoryMapPath != null && memoryMapPath.isNotEmpty) {
          final mapResult = await lifecycleService.loadMemoryMap(memoryMapPath);
          if (mapResult[0] != true) {
            throw SynthesizerException('Failed to load memory map: ${mapResult[1]}');
          }
        }

        // Define all hook code (including pre-seeded overrides on iteration 1)
        if (definedHooks.isNotEmpty) {
          for (final entry in definedHooks.entries) {
            await lifecycleService.defineHook(entry.key, entry.value);
          }
        }

        // Map accumulated hooks
        if (hookMap.isNotEmpty) {
          await lifecycleService.mapHooks(hookMap);
        }

        // Start emulation and wait for a pause event
        final pauseEvent = await _startAndWaitForPause(
          startFrom: startFrom,
          endAt: endAt,
          pauseOnUnhandled: true,
        );

        // Handle the pause event
        if (pauseEvent == null) {
          // Emulation completed without pausing — success!
          stopwatch.stop();
          final result = SynthesizerResult(
            success: true,
            totalIterations: iteration,
            resolvedHooks: Map.unmodifiable(hookMap),
            resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
            totalDuration: stopwatch.elapsed,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        if (pauseEvent.unhandledAccess != true || pauseEvent.symbol == null) {
          // Paused for a non-unhandled-access reason (e.g., user pause, breakpoint)
          // Wait for the user to resume or abort
          print('[Synthesizer] Non-unhandled pause at ${pauseEvent.symbol}, '
              'waiting for resume...');
          await _waitForResumeOrReset();
          continue;
        }

        // Unhandled access — identify the problematic symbol
        final symbol = pauseEvent.symbol!;
        print('[Synthesizer] Unhandled access at symbol: $symbol');

        // If this symbol has a forced override, don't try alternatives — fail
        if (overriddenSymbols.contains(symbol)) {
          print('[Synthesizer] Symbol "$symbol" has a forced override that failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = SynthesizerResult(
            success: false,
            totalIterations: iteration,
            resolvedHooks: Map.unmodifiable(hookMap),
            resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
            failedSymbol: symbol,
            totalDuration: stopwatch.elapsed,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        // Get available hooks for this symbol (cached)
        if (!hookCache.containsKey(symbol)) {
          var hooks = await artifactDb.getArtifactsForSymbolByName(
            elfHash,
            symbol,
          );
          // Reorder: if user has a preference for this symbol, move that
          // artifact to the front so it's tried first.
          final preferredId = hookPreferences[symbol];
          if (preferredId != null) {
            final preferredIndex = hooks.indexWhere((a) => a.id == preferredId);
            if (preferredIndex > 0) {
              final preferred = hooks.removeAt(preferredIndex);
              hooks = [preferred, ...hooks];
            }
          }
          print('[Synthesizer] Lookup hooks for "$symbol" (elfHash=${elfHash.substring(0, 8)}...): '
              'found ${hooks.length}${preferredId != null ? ' (preferred: $preferredId)' : ''}');
          hookCache[symbol] = hooks;
        }
        final hooks = hookCache[symbol]!;

        if (hooks.isEmpty) {
          // No hooks available — this should not happen if registration was correct
          print('[Synthesizer] ERROR: No hooks found for "$symbol" — '
              'artifact DB registration may have failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = SynthesizerResult(
            success: false,
            totalIterations: iteration,
            resolvedHooks: Map.unmodifiable(hookMap),
            resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
            failedSymbol: symbol,
            totalDuration: stopwatch.elapsed,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        // Get the current hook index for this symbol
        final currentIndex = hookIndex[symbol] ?? 0;

        if (currentIndex >= hooks.length) {
          // All hooks exhausted for this symbol — stop
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = SynthesizerResult(
            success: false,
            totalIterations: iteration,
            resolvedHooks: Map.unmodifiable(hookMap),
            resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
            failedSymbol: symbol,
            totalDuration: stopwatch.elapsed,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        // Select the next hook
        final hookArtifact = hooks[currentIndex];
        final hookName = '${symbol}_hook_$currentIndex';
        final hookCode = hookArtifact.artifactData;

        // Store hook definition and update maps
        definedHooks[hookName] = hookCode;
        hookMap[symbol] = hookName;
        hookIndex[symbol] = currentIndex + 1; // advance for next try if needed

        _eventController.add(SynthesizerHookApplied(
          iteration: iteration,
          symbol: symbol,
          hookName: hookName,
          hookIndex: currentIndex,
          totalHooksForSymbol: hooks.length,
        ));

        print('[Synthesizer] Applied hook "$hookName" '
            '(${currentIndex + 1}/${hooks.length}) for $symbol');
      }

      // Loop exited — either max iterations or cancelled
      stopwatch.stop();
      final result = SynthesizerResult(
        success: false,
        totalIterations: iteration,
        resolvedHooks: Map.unmodifiable(hookMap),
        resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
        failedSymbol: _isRunning ? 'MAX_ITERATIONS_REACHED' : 'CANCELLED',
        totalDuration: stopwatch.elapsed,
      );
      _eventController.add(SynthesizerCompleted(
        iteration: iteration,
        result: result,
      ));
      return result;
    } finally {
      // Reset Renode state so it's clean for the next run
      try {
        await lifecycleService.reset();
      } catch (_) {
        // Best-effort — lifecycle service may already be disconnected
      }
      _isRunning = false;
    }
  }

  /// Start emulation and wait for either a pause event or timeout.
  ///
  /// Returns the PausedEvent if emulation paused, or null if emulation
  /// appears to have completed (no pause within timeout).
  ///
  /// Uses a 'started'/'resumed' gate to ignore stale pause events from
  /// prior reset/load cycles. Only accepts pauses after the server confirms
  /// execution actually began.
  Future<PausedEvent?> _startAndWaitForPause({
    String? startFrom,
    List<String>? endAt,
    required bool pauseOnUnhandled,
  }) async {
    final completer = Completer<PausedEvent?>();
    bool executionStarted = false;

    // Gate: only accept pause events after 'started'/'resumed' confirms
    // execution actually began. This filters out stale pause events from
    // the reset/load sequence (e.g., machine-paused during Clear).
    late StreamSubscription<void> startedSub;
    startedSub = lifecycleService.onStarted.listen((_) {
      executionStarted = true;
      startedSub.cancel();
    });
    late StreamSubscription<void> resumedSub;
    resumedSub = lifecycleService.onResumed.listen((_) {
      executionStarted = true;
      resumedSub.cancel();
    });

    // Listen for pause events, only accept after execution started
    late StreamSubscription<PausedEvent> pauseSub;
    pauseSub = lifecycleService.onPaused.listen((event) {
      if (executionStarted && !completer.isCompleted) {
        pauseSub.cancel();
        startedSub.cancel();
        resumedSub.cancel();
        completer.complete(event);
      }
    });

    // Start emulation
    final result = await lifecycleService.start(
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
    );

    if (result[0] != true) {
      pauseSub.cancel();
      startedSub.cancel();
      resumedSub.cancel();
      throw SynthesizerException('Failed to start emulation: ${result[1]}');
    }

    // Wait for pause with a generous timeout
    // If firmware runs cleanly, we won't get a pause — use timeout as success signal
    try {
      return await completer.future.timeout(
        const Duration(seconds: 30),
      );
    } on TimeoutException {
      pauseSub.cancel();
      startedSub.cancel();
      resumedSub.cancel();
      // No pause within timeout — assume emulation is running cleanly
      return null;
    }
  }

  /// Wait for the user to resume or reset emulation.
  ///
  /// Used when the synthesizer encounters a non-unhandled-access pause.
  Future<void> _waitForResumeOrReset() async {
    final completer = Completer<void>();

    late StreamSubscription<void> resumeSub;
    late StreamSubscription<void> resetSub;

    resumeSub = lifecycleService.onResumed.listen((_) {
      if (!completer.isCompleted) {
        resumeSub.cancel();
        resetSub.cancel();
        completer.complete();
      }
    });

    resetSub = lifecycleService.onReset.listen((_) {
      if (!completer.isCompleted) {
        resumeSub.cancel();
        resetSub.cancel();
        completer.complete();
      }
    });

    await completer.future;
  }

  /// Load firmware with retry logic (mirrors EmulationWorkflow).
  Future<void> _loadFirmwareWithRetry(String baseImagePath, String elfPath) async {
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 2);

    List<dynamic> loadResult = [false, 'Not attempted'];
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      loadResult = await lifecycleService.load(baseImagePath, elfPath);

      if (loadResult[0] == true) {
        return;
      }

      if (attempt < maxRetries - 1) {
        print('[Synthesizer] Load failed, retrying in ${retryDelay.inSeconds}s...');
        await Future.delayed(retryDelay);
      }
    }

    throw SynthesizerException(
        'Failed to load firmware after $maxRetries attempts: ${loadResult[1]}');
  }

  /// Cancel a running synthesis (from external control).
  void cancel() {
    _isRunning = false;
  }

  void dispose() {
    _eventController.close();
  }
}

/// Exception thrown when synthesizer operations fail.
class SynthesizerException implements Exception {
  final String message;

  SynthesizerException(this.message);

  @override
  String toString() => 'SynthesizerException: $message';
}
