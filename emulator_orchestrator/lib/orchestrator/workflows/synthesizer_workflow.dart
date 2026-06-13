import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:signatures/signatures.dart' show FunctionSignature;

import '../../data/database/artifact_database.dart';
import '../../data/models/hook_binding.dart';
import '../../data/models/synthesis_manifest.dart';
import '../../data/models/synthesizer_result.dart';
import '../../data/services/llm_hook_generator.dart' show LlmHookGenerator, PlatformFacts;
import '../engine/emulation_controller.dart';
import '../engine/paused_event.dart';
import '../events/synthesizer_events.dart';
import '../hook_spec.dart';

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
/// The synthesizer uses the existing EmulationWorkflow for the initial engine
/// startup, then manages subsequent reset/restart cycles directly via the
/// emulation control channel (avoiding engine restarts between iterations).
class SynthesizerWorkflow {
  final EmulationController emulationController;
  final ArtifactDatabase artifactDb;

  /// Event stream for progress reporting.
  final _eventController = StreamController<SynthesizerEvent>.broadcast();
  Stream<SynthesizerEvent> get events => _eventController.stream;

  /// Whether a synthesis run is currently active.
  var _isRunning = false;
  bool get isRunning => _isRunning;

  SynthesizerWorkflow({
    required this.emulationController,
    required this.artifactDb,
  });

  /// Run the synthesis loop.
  ///
  /// Prerequisites: The emulation engine must already be running and the
  /// control channel connected (i.e., EmulationWorkflow.start() has been
  /// called and firmware is loaded). The synthesizer takes over from there,
  /// managing reset/hook/restart cycles.
  ///
  /// Stops immediately if any symbol exhausts all hook candidates.
  Future<SynthesizerResult> run({
    required String elfPath,
    required String elfHash,
    required String baseImagePath,
    String? startFrom,
    List<String>? endAt,
    int maxIterations = 10,
    Map<String, int> hookPreferences = const {},
    Map<String, int> hookOverrides = const {},
    Map<String, String> hookOverrideScopes = const {},
    Map<String, String> resolvedHooks = const {},
    Map<String, HookSpec> commsHooks = const {},
    Map<String, HookBinding> hookBindings = const {},
    String? memoryMapPath,
    LlmHookGenerator? llmGenerator,
    PlatformFacts? platform,
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
    final definedHooks = <String, String>{};    // hookName → hookCode
    final hookScopes = <String, String?>{};     // hookName → optional Renode scope
    // Mutable copy so the LLM fallback can add bindings as it generates;
    // the caller's map (which lives in the project's Emulator) is not
    // mutated until the UI's autosave snapshots the provider state.
    final activeBindings = Map<String, HookBinding>.from(hookBindings);
    // Symbols where we've already invoked the LLM fallback this run.
    // Prevents an infinite retry loop on a generated hook that itself
    // causes an unhandled access at the same symbol.
    final triedLlm = <String>{};
    // Manifest accumulator — per-symbol ordered list of hook
    // applications. Pre-seeded layers contribute exactly one entry;
    // iteration adds another entry per attempt. At result time the
    // LAST entry becomes the applied_hook and the earlier ones become
    // previous_attempts.
    final attempts = <String, List<_ManifestAttempt>>{};
    void recordAttempt(String symbol, _ManifestAttempt a) =>
        (attempts[symbol] ??= []).add(a);
    final runStart = DateTime.now();
    final runId = runStart.toIso8601String();
    final elfFileName = p.basename(elfPath);

    var iteration = 0;

    Map<String, String> buildHookCodeMap() => {
        for (final entry in hookMap.entries)
          if (definedHooks.containsKey(entry.value))
            entry.key: definedHooks[entry.value]!,
      };

    SynthesizerResult buildResult({
      required bool success,
      String? failedSymbol,
    }) {
      final manifest = _buildManifest(
        elfHash: elfHash,
        elfFileName: elfFileName,
        runId: runId,
        success: success,
        totalIterations: iteration,
        duration: stopwatch.elapsed,
        failedSymbol: failedSymbol,
        attempts: attempts,
      );
      return SynthesizerResult(
        success: success,
        totalIterations: iteration,
        resolvedHooks: Map.unmodifiable(hookMap),
        resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
        failedSymbol: failedSymbol,
        totalDuration: stopwatch.elapsed,
        manifest: manifest,
      );
    }

    // Pre-seed forced overrides (unconditional substitutions). Each override
    // may carry a user-supplied Renode scope (plan C2) — empty / missing is
    // treated as no-scope.
    final overriddenSymbols = <String>{};
    for (final entry in hookOverrides.entries) {
      final artifact = await artifactDb.getArtifactById(entry.value);
      if (artifact != null) {
        final hookName = '${entry.key}_override';
        final rawScope = hookOverrideScopes[entry.key];
        final scope = (rawScope == null || rawScope.isEmpty) ? null : rawScope;
        definedHooks[hookName] = artifact.artifactData;
        hookScopes[hookName] = scope;
        hookMap[entry.key] = hookName;
        overriddenSymbols.add(entry.key);
        recordAttempt(
            entry.key,
            _ManifestAttempt(
              code: artifact.artifactData,
              kind: ManifestDecisionKind.forcedOverride,
              source: 'user.hookOverrides',
              artifactId: artifact.id,
              scope: scope,
            ));
        print('[Synthesizer] Pre-seeded override for "${entry.key}" '
            '(artifact #${entry.value}, scope ${scope ?? "—"})');
      }
    }

    // Pre-seed comms-bus hooks (one per virtualized/assigned symbol). Comms
    // hooks carry a per-protocol scope so all hooks of a protocol share
    // Python globals (Workstream B). They're marked overridden so the
    // synthesizer never iterates alternatives for these symbols.
    for (final entry in commsHooks.entries) {
      if (overriddenSymbols.contains(entry.key)) continue; // forced override wins
      final hookName = '${entry.key}_comms';
      definedHooks[hookName] = entry.value.code;
      hookScopes[hookName] = entry.value.scope;
      hookMap[entry.key] = hookName;
      overriddenSymbols.add(entry.key);
      recordAttempt(
          entry.key,
          _ManifestAttempt(
            code: entry.value.code,
            kind: ManifestDecisionKind.comms,
            source: 'comms:${entry.value.scope ?? "unscoped"}',
            scope: entry.value.scope,
          ));
      print('[Synthesizer] Pre-seeded comms hook for "${entry.key}" (scope ${entry.value.scope})');
    }

    // Pre-seed previously resolved hooks (warm start). Overrides + comms take precedence.
    for (final entry in resolvedHooks.entries) {
      if (!overriddenSymbols.contains(entry.key)) {
        final hookName = '${entry.key}_resolved';
        definedHooks[hookName] = entry.value;
        hookMap[entry.key] = hookName;
        recordAttempt(
            entry.key,
            _ManifestAttempt(
              code: entry.value,
              kind: ManifestDecisionKind.warmStart,
              source: 'warm_start',
            ));
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

        // Reset state and reload firmware for a clean CPU state on every
        // iteration (including the first) — emulationWorkflow.start() may
        // have already paused execution mid-firmware.
        await emulationController.reset();
        await Future.delayed(const Duration(milliseconds: 500));
        await _loadFirmwareWithRetry(baseImagePath, elfPath);

        if (memoryMapPath != null && memoryMapPath.isNotEmpty) {
          await emulationController.loadMemoryMap(memoryMapPath);
        }

        // (Re)define all hook code (including pre-seeded overrides on iter 1)
        for (final entry in definedHooks.entries) {
          await emulationController.defineHook(
            entry.key,
            entry.value,
            scope: hookScopes[entry.key],
          );
        }

        if (hookMap.isNotEmpty) {
          await emulationController.mapHooks(hookMap);
        }

        final pauseEvent = await _startAndWaitForPause(
          startFrom: startFrom,
          endAt: endAt,
          pauseOnUnhandled: true,
        );

        if (pauseEvent == null) {
          // Firmware ran cleanly — success.
          stopwatch.stop();
          final result = buildResult(success: true);
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        if (pauseEvent.unhandledAccess != true || pauseEvent.symbol == null) {
          print('[Synthesizer] Non-unhandled pause at ${pauseEvent.symbol}, '
              'waiting for resume...');
          await _waitForResumeOrReset();
          continue;
        }

        final symbol = pauseEvent.symbol!;
        print('[Synthesizer] Unhandled access at symbol: $symbol');

        // Forced override that failed: bail out, don't try alternatives.
        if (overriddenSymbols.contains(symbol)) {
          print('[Synthesizer] Symbol "$symbol" has a forced override that failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(success: false, failedSymbol: symbol);
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        if (!hookCache.containsKey(symbol)) {
          var hooks = await artifactDb.getArtifactsForSymbolByName(
            elfHash,
            symbol,
          );
          // Effective-score sort per the radiant-inventing-dream plan §2.0:
          //   COALESCE(binding.fidelity, artifact.intrinsicScore, 0.0) DESC,
          //   origin ASC, id ASC.
          // The per-project binding's fidelity overrides the artifact's
          // intrinsic floor when present. Without a binding, the intrinsic
          // floor drives ordering — generic `return 0` (0.0) sinks below
          // anything user-authored or specialized.
          final binding = activeBindings[symbol];
          double scoreFor(Artifact a) {
            if (binding != null && binding.artifactId == a.id) {
              return binding.fidelity;
            }
            return a.intrinsicScore ?? 0.0;
          }
          hooks = [...hooks]..sort((a, b) {
              final byScore = scoreFor(b).compareTo(scoreFor(a));
              if (byScore != 0) return byScore;
              final byOrigin = a.origin.compareTo(b.origin);
              if (byOrigin != 0) return byOrigin;
              return a.id.compareTo(b.id);
            });
          // If the user has a preference for this symbol, try that artifact
          // first — preserved on top of the effective-score sort as the
          // soft re-order signal it's always been.
          final preferredId = hookPreferences[symbol];
          if (preferredId != null) {
            final preferredIndex = hooks.indexWhere((a) => a.id == preferredId);
            if (preferredIndex > 0) {
              final preferred = hooks.removeAt(preferredIndex);
              hooks = [preferred, ...hooks];
            }
          }
          print('[Synthesizer] Lookup hooks for "$symbol" (elfHash=${elfHash.substring(0, 8)}...): '
              'found ${hooks.length}${preferredId != null ? ' (preferred: $preferredId)' : ''}'
              '${binding != null ? ' (binding: artifact ${binding.artifactId} @ '
                  'fidelity ${binding.fidelity.toStringAsFixed(2)} '
                  'from ${binding.provenance})' : ''}');
          hookCache[symbol] = hooks;
        }
        final hooks = hookCache[symbol]!;

        if (hooks.isEmpty) {
          print('[Synthesizer] ERROR: No hooks found for "$symbol" — '
              'artifact DB registration may have failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(success: false, failedSymbol: symbol);
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        final currentIndex = hookIndex[symbol] ?? 0;

        if (currentIndex >= hooks.length) {
          // On-demand LLM fallback: when every DB-cached candidate has
          // been tried and none survives, ask the LLM for a hook —
          // once per symbol. Insert the result as a Replacement
          // artifact + a binding at fidelity 0.5 (pre-harness, per
          // plan §2.1), then refresh the cache so the next loop
          // iteration tries the new candidate.
          if (llmGenerator != null && !triedLlm.contains(symbol)) {
            triedLlm.add(symbol);
            final llmBinding = await _tryLlmFallback(
              symbol: symbol,
              iteration: iteration,
              elfHash: elfHash,
              llmGenerator: llmGenerator,
              platform: platform,
            );
            if (llmBinding != null) {
              activeBindings[symbol] = llmBinding;
              // Clear the per-symbol cache so the next iteration
              // re-queries with the new artifact in the candidate
              // list. Reset the hookIndex so the fresh sort starts
              // from index 0.
              hookCache.remove(symbol);
              hookIndex.remove(symbol);
              continue;
            }
            // Generation failed (empty output, network error, etc.) —
            // fall through to the exhausted branch below.
          }

          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(success: false, failedSymbol: symbol);
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        final hookArtifact = hooks[currentIndex];
        final hookName = '${symbol}_hook_$currentIndex';
        final hookCode = hookArtifact.artifactData;

        // Classify the attempt for the manifest: binding-driven when
        // the chosen artifact matches an active binding for the
        // symbol (covers classifier-seeded, LLM-seeded, and
        // user-Replacement-back-fill bindings); llm_on_demand when
        // the LLM was just invoked for this symbol and produced the
        // chosen artifact; iteration_fallback otherwise.
        final binding = activeBindings[symbol];
        final bindingMatches =
            binding != null && binding.artifactId == hookArtifact.id;

        definedHooks[hookName] = hookCode;
        // Carry the binding's Renode scope onto the deploy when this
        // iteration-applied hook came from a binding. Mirrors what the
        // override / comms / warm-start pre-seed layers do for their
        // own attempts. Bindings without a scope (stateless hooks,
        // pre-scope-migration bindings) deploy unscoped — same as
        // today's behavior for the no-binding case.
        if (bindingMatches && binding.scope != null) {
          hookScopes[hookName] = binding.scope;
        }
        hookMap[symbol] = hookName;
        hookIndex[symbol] = currentIndex + 1;
        final ManifestDecisionKind attemptKind;
        final String attemptSource;
        final LlmInvocation? llmInvocation;
        if (triedLlm.contains(symbol) && bindingMatches) {
          attemptKind = ManifestDecisionKind.llmOnDemand;
          attemptSource = binding.provenance;
          // Token-count telemetry isn't plumbed through the LLM
          // generator yet. Record the model tag now; tokens can land
          // later without a schema bump.
          llmInvocation = LlmInvocation(
            model: binding.provenance.startsWith('llm:')
                ? binding.provenance.substring(4)
                : binding.provenance,
          );
        } else if (bindingMatches) {
          attemptKind = ManifestDecisionKind.binding;
          attemptSource = binding.provenance;
          llmInvocation = null;
        } else {
          attemptKind = ManifestDecisionKind.iterationFallback;
          attemptSource = hookArtifact.origin == 'default'
              ? 'default_template:#${hookArtifact.id}'
              : 'user_artifact:#${hookArtifact.id}';
          llmInvocation = null;
        }
        recordAttempt(
            symbol,
            _ManifestAttempt(
              code: hookCode,
              kind: attemptKind,
              source: attemptSource,
              artifactId: hookArtifact.id,
              scope: bindingMatches ? binding.scope : null,
              fidelity: bindingMatches ? binding.fidelity : null,
              iterationIndex: currentIndex,
              llmInvocation: llmInvocation,
            ));

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

      stopwatch.stop();
      final result = buildResult(
        success: false,
        failedSymbol: _isRunning ? 'MAX_ITERATIONS_REACHED' : 'CANCELLED',
      );
      _eventController.add(SynthesizerCompleted(
        iteration: iteration,
        result: result,
      ));
      return result;
    } finally {
      // Best-effort cleanup; control channel may already be disconnected.
      try {
        await emulationController.reset();
      } catch (_) {}
      _isRunning = false;
    }
  }

  /// Start emulation and wait for either a pause event or timeout.
  ///
  /// Returns the PausedEvent if emulation paused, or null if emulation
  /// appears to have completed (no pause within timeout).
  ///
  /// Uses a 'started'/'resumed' gate to ignore stale pause events from
  /// prior reset/load cycles. Only accepts pauses after the engine confirms
  /// execution actually began.
  Future<PausedEvent?> _startAndWaitForPause({
    required bool pauseOnUnhandled, String? startFrom,
    List<String>? endAt,
  }) async {
    final completer = Completer<PausedEvent?>();
    var executionStarted = false;

    late StreamSubscription<void> startedSub;
    startedSub = emulationController.onStarted.listen((_) {
      executionStarted = true;
      startedSub.cancel();
    });
    late StreamSubscription<void> resumedSub;
    resumedSub = emulationController.onResumed.listen((_) {
      executionStarted = true;
      resumedSub.cancel();
    });

    late StreamSubscription<PausedEvent> pauseSub;
    pauseSub = emulationController.onPaused.listen((event) {
      if (executionStarted && !completer.isCompleted) {
        pauseSub.cancel();
        startedSub.cancel();
        resumedSub.cancel();
        completer.complete(event);
      }
    });

    try {
      await emulationController.start(
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
      );
    } catch (e, st) {
      stderr
        ..writeln('[synthesizer._startAndWaitForPause] start() threw: $e')
        ..writeln(st.toString());
      pauseSub.cancel();
      startedSub.cancel();
      resumedSub.cancel();
      throw SynthesizerException('Failed to start emulation: $e');
    }

    try {
      return await completer.future.timeout(
        const Duration(seconds: 30),
      );
    } on TimeoutException {
      pauseSub.cancel();
      startedSub.cancel();
      resumedSub.cancel();
      // No pause within timeout — assume emulation completed cleanly.
      return null;
    }
  }

  /// Wait for the user to resume or reset emulation.
  Future<void> _waitForResumeOrReset() async {
    final completer = Completer<void>();

    late StreamSubscription<void> resumeSub;
    late StreamSubscription<void> resetSub;

    resumeSub = emulationController.onResumed.listen((_) {
      if (!completer.isCompleted) {
        resumeSub.cancel();
        resetSub.cancel();
        completer.complete();
      }
    });

    resetSub = emulationController.onReset.listen((_) {
      if (!completer.isCompleted) {
        resumeSub.cancel();
        resetSub.cancel();
        completer.complete();
      }
    });

    await completer.future;
  }

  Future<void> _loadFirmwareWithRetry(String baseImagePath, String elfPath) async {
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 2);

    Object? lastError;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await emulationController.load(baseImagePath, elfPath);
        return;
      } catch (e) {
        lastError = e;
        if (attempt < maxRetries - 1) {
          print('[Synthesizer] Load failed, retrying in ${retryDelay.inSeconds}s...');
          await Future.delayed(retryDelay);
        }
      }
    }

    throw SynthesizerException(
        'Failed to load firmware after $maxRetries attempts: $lastError');
  }

  /// Generate a hook for [symbol] via the LLM, persist it as a
  /// Replacement artifact, and return a binding pointing at the new
  /// artifact at fidelity 0.5 (pre-harness, per plan §2.1). Returns
  /// null when the LLM produces nothing usable (empty body, no
  /// signature row, generator error) — the caller falls through to
  /// the symbol-exhausted failure path.
  ///
  /// Emits [SynthesizerLlmGenerating] before the LLM call so the UI
  /// can flip its progress indicator from "iteration N waiting…" to
  /// "LLM generating for $symbol…", and [SynthesizerLlmGenerated]
  /// after a successful insert.
  Future<HookBinding?> _tryLlmFallback({
    required String symbol,
    required int iteration,
    required String elfHash,
    required LlmHookGenerator llmGenerator,
    required PlatformFacts? platform,
  }) async {
    final modelTag = llmGenerator.client.model;
    _eventController.add(SynthesizerLlmGenerating(
      iteration: iteration,
      symbol: symbol,
      modelTag: modelTag,
    ));
    print('[Synthesizer] LLM fallback for "$symbol" via $modelTag '
        '(every DB candidate failed) …');

    // Look up the signature — required input for the generator's
    // classifier short-circuit and its prompt's `## Signature` block.
    // Missing-signature isn't fatal (the generator can still produce
    // a hook without it), so we pass null in that case.
    final sigRow = await artifactDb.getSignatureFor(
      elfHash: elfHash,
      symbolName: symbol,
    );
    FunctionSignature? signature;
    if (sigRow != null) {
      try {
        signature = FunctionSignature.fromJson(
          symbol,
          jsonDecode(sigRow.signatureJson) as Map<String, dynamic>,
        );
      } catch (_) {
        // Malformed signature JSON — log and continue without it.
      }
    }

    final buffer = StringBuffer();
    try {
      await for (final chunk in llmGenerator.generate(
        userPrompt: 'Substitute for $symbol in emulation. The goal is '
            'to let the caller continue without generating unhandled '
            'memory accesses — NOT to reproduce what the real hardware '
            'would do.',
        targetSymbol: symbol,
        elfHash: elfHash,
        platform: platform,
        signature: signature,
      )) {
        buffer.write(chunk);
      }
    } catch (e) {
      print('[Synthesizer] LLM fallback failed for "$symbol": $e');
      return null;
    }
    final body = buffer.toString().trim();
    if (body.isEmpty) {
      print('[Synthesizer] LLM returned empty body for "$symbol"');
      return null;
    }

    // Reuse an existing artifact when the LLM happens to emit a body
    // that matches one already in the pool (typically the catalog
    // no-op template). Otherwise insert as a new Replacement.
    final existing = await artifactDb.findArtifactByBody(body);
    final int artifactId;
    if (existing != null) {
      artifactId = existing.id;
    } else {
      artifactId = await artifactDb.addArtifact(
        artifactType: 'renode_hook',
        artifactData: body,
        origin: 'user',
        architecture: 'ARM',
        targetSymbolName: symbol,
        intrinsicScore: 0.5,
      );
    }

    final binding = HookBinding(
      artifactId: artifactId,
      fidelity: 0.5,
      provenance: 'llm:$modelTag',
      createdAt: DateTime.now(),
      // Per-symbol scope as a default so anything stateful the LLM
      // emitted (incrementVariable / variables.getVariable / etc.)
      // gets a persistent Python interpreter keyed on the function
      // name. Stateless bodies ignore the scope. Cheap insurance —
      // see the scope-handling plan §Per-creation-site policy.
      scope: symbol,
    );
    _eventController.add(SynthesizerLlmGenerated(
      iteration: iteration,
      symbol: symbol,
      artifactId: artifactId,
      fidelity: binding.fidelity,
    ));
    print('[Synthesizer] LLM fallback produced artifact $artifactId for '
        '"$symbol" (${body.split('\n').length} lines)');
    return binding;
  }

  /// Cancel a running synthesis (from external control).
  void cancel() {
    _isRunning = false;
  }

  void dispose() {
    _eventController.close();
  }
}


/// Per-symbol, per-attempt scratchpad the manifest builder uses.
/// One of these gets recorded each time the synthesizer applies a
/// hook to a symbol (pre-seeded or iteration-driven). The last
/// entry in a symbol's list becomes the manifest's `applied_hook`;
/// earlier entries become `previous_attempts`.
class _ManifestAttempt {
  _ManifestAttempt({
    required this.code,
    required this.kind,
    required this.source,
    this.artifactId,
    this.scope,
    this.fidelity,
    this.iterationIndex,
    this.llmInvocation,
  });

  final String code;
  final ManifestDecisionKind kind;
  final String source;
  final int? artifactId;
  final String? scope;
  final double? fidelity;
  final int? iterationIndex;
  final LlmInvocation? llmInvocation;
}

/// Build a [SynthesisManifest] from the recorded per-symbol attempts.
SynthesisManifest _buildManifest({
  required String elfHash,
  required String elfFileName,
  required String runId,
  required bool success,
  required int totalIterations,
  required Duration duration,
  required String? failedSymbol,
  required Map<String, List<_ManifestAttempt>> attempts,
}) {
  final decisions = <ManifestDecision>[];
  final symbols = attempts.keys.toList()..sort();
  for (final symbol in symbols) {
    final list = attempts[symbol]!;
    if (list.isEmpty) continue;
    final applied = list.last;
    final priors = list.length > 1
        ? list
            .sublist(0, list.length - 1)
            .map((a) => PreviousAttempt(
                  artifactId: a.artifactId ?? -1,
                  outcome: 'unhandled_access_repeat',
                ))
            .toList()
        : null;
    decisions.add(ManifestDecision(
      symbol: symbol,
      appliedHook: AppliedHook(
        artifactId: applied.artifactId,
        bodyHash: AppliedHook.hashBody(applied.code),
        scope: applied.scope,
      ),
      decisionKind: applied.kind,
      decisionSource: applied.source,
      fidelityAtDecision: applied.fidelity,
      iterationIndex: applied.iterationIndex,
      previousAttempts: priors,
      llmInvocation: applied.llmInvocation,
    ));
  }
  return SynthesisManifest(
    manifestVersion: 1,
    elfHash: elfHash,
    elfFileName: elfFileName,
    synthesizerRunId: runId,
    result: ManifestRunResult(
      success: success,
      totalIterations: totalIterations,
      durationSeconds: duration.inMilliseconds / 1000.0,
    ),
    decisions: decisions,
    failedSymbol: failedSymbol,
  );
}

/// Exception thrown when synthesizer operations fail.
class SynthesizerException implements Exception {
  final String message;

  SynthesizerException(this.message);

  @override
  String toString() => 'SynthesizerException: $message';
}
