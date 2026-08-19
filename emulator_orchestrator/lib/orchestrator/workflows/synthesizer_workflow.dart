import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:resect_signatures/resect_signatures.dart' show FunctionSignature;

import '../../data/database/artifact_database.dart';
import '../../data/models/hook_binding.dart';
import '../../data/models/symbol_group.dart';
import '../../data/models/synthesis_manifest.dart';
import '../../data/models/synthesizer_result.dart';
import '../../services/llm/llm_hook_generator.dart' show LlmHookGenerator, PlatformFacts;
import '../engine/emulation_controller.dart';
import '../engine/paused_event.dart';
import '../events/synthesizer_events.dart';
import '../hook_spec.dart';
import '../manifest_builder.dart';

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
/// Minimum effective score for a candidate to count as "specialized"
/// (a classifier binding or user artifact, both 0.5 today) rather than
/// a generic template (≤0.2). Once no candidate at or above this score
/// remains for a symbol, the synthesizer engages the LLM to author one
/// instead of grinding through generics. Tunable; see the "per-symbol
/// hook appropriateness scoring" item in TODO.txt for why this flat
/// global floor is a stopgap.
const _kLlmEngageMinScore = 0.5;

/// Per-operation ceiling on a single Renode control round-trip
/// (reset / load / defineHook / mapHooks / start). Normal ops are
/// sub-second to a few seconds; this only trips when the engine has
/// stopped responding. It is a SAFETY NET, not a correctness fix — the
/// real cause of a comms-read wedge is a missing bus server (see the
/// CLI's CommsBusService wiring). Without this net, though, any future
/// unresponsive-engine bug would hang the loop forever instead of
/// failing the round. Generous so it never false-trips a slow load.
const _kRenodeOpTimeout = Duration(seconds: 60);

/// True when no specialized candidate (effective score >= [minScore])
/// remains to try at [nextIndex] in the score-DESC candidate list —
/// i.e. the symbol's appropriate hooks are used up and it's time to
/// author one. Running past the end of the list (full exhaustion) also
/// counts. Pure so the LLM-engage decision is unit-testable without a
/// live synthesizer/Renode.
bool specializedCandidatesExhausted({
  required int nextIndex,
  required List<double> scoresDesc,
  required double minScore,
}) =>
    nextIndex >= scoresDesc.length || scoresDesc[nextIndex] < minScore;

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
    int maxIterations = 500,
    Map<String, int> hookPreferences = const {},
    Map<String, int> hookOverrides = const {},
    Map<String, String> hookOverrideScopes = const {},
    Map<String, String> resolvedHooks = const {},
    Map<String, HookSpec> commsHooks = const {},
    Map<String, HookBinding> hookBindings = const {},
    List<SymbolGroup> symbolGroups = const [],
    Map<String, GroupOverrideState> groupOverrides = const {},
    String? memoryMapPath,
    LlmHookGenerator? llmGenerator,
    PlatformFacts? platform,
  }) async {
    if (_isRunning) {
      throw SynthesizerException('Synthesizer is already running');
    }

    _isRunning = true;
    final stopwatch = Stopwatch()..start();

    // Timing instrumentation for the manifest: every stop condition
    // stamped with the run clock (first entry = time to first crash),
    // per-iteration wall clock, and where non-emulation time went
    // (hook candidate selection vs LLM hook authoring).
    final stops = <StopTiming>[];
    final iterationTimings = <IterationTiming>[];
    Duration? currentIterStart;
    void closeIteration(int iterIndex) {
      if (currentIterStart == null) return;
      iterationTimings.add(IterationTiming(
        iterationIndex: iterIndex,
        wallClockSeconds:
            (stopwatch.elapsed - currentIterStart!).inMilliseconds / 1000.0,
      ));
      currentIterStart = null;
    }

    final selectionWatch = Stopwatch();
    final generationWatch = Stopwatch();

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
    // Object-group index: symbol → its recognized group. The first time
    // any member faults, the whole group is force-installed with its
    // shared scope (see `SymbolGroupClassifier`). `appliedGroupScopes`
    // ensures that happens at most once per group per run.
    final groupOf = <String, SymbolGroup>{};
    for (final g in symbolGroups) {
      for (final member in g.members.keys) {
        groupOf[member] = g;
      }
    }
    final appliedGroupScopes = <String>{};
    // Groups the LLM cleared: never auto-applied on fault (see groupOverrides).
    final suppressedGroupScopes = {
      for (final e in groupOverrides.entries)
        if (e.value == GroupOverrideState.suppressed) e.key,
    };
    // Manifest accumulator — per-symbol ordered list of hook
    // applications. Pre-seeded layers contribute exactly one entry;
    // iteration adds another entry per attempt. At result time the
    // LAST entry becomes the applied_hook and the earlier ones become
    // previous_attempts.
    final attempts = <String, List<ManifestAttempt>>{};
    void recordAttempt(String symbol, ManifestAttempt a) =>
        (attempts[symbol] ??= []).add(a);

    // Install every member of a group override plan: define + map each hook
    // with the shared scope, drop stale per-symbol iteration state, record a
    // groupOverride manifest attempt, and mark the scope applied. Shared by
    // the forced pre-seed and the on-fault escalation.
    void installGroupPlan(GroupOverridePlan plan) {
      appliedGroupScopes.add(plan.scope);
      for (final m in plan.members) {
        final hookName = '${m.symbol}_group';
        definedHooks[hookName] = m.code;
        hookScopes[hookName] = m.scope;
        hookMap[m.symbol] = hookName;
        hookCache.remove(m.symbol);
        hookIndex.remove(m.symbol);
        recordAttempt(
          m.symbol,
          ManifestAttempt(
            code: m.code,
            kind: ManifestDecisionKind.groupOverride,
            source: 'group_override:${plan.scope}',
            scope: m.scope,
          ),
        );
      }
    }
    final runStart = DateTime.now();
    final runId = runStart.toIso8601String();
    final elfFileName = p.basename(elfPath);

    var iteration = 0;
    // Tracks the LAST symbol the firmware tried to call before the
    // synthesizer terminated, regardless of success. Distinct from
    // `failedSymbol` (set only on !success). Updated each loop
    // iteration when an unhandled pause is observed. Used by the
    // LLM advisor's halt-point line so it can name the right symbol
    // on `success=true` runs that ended with the firmware still
    // spinning on a busy-ready hook.
    String? lastObservedPauseSymbol;

    Map<String, String> buildHookCodeMap() => {
        for (final entry in hookMap.entries)
          if (definedHooks.containsKey(entry.value))
            entry.key: definedHooks[entry.value]!,
      };

    SynthesizerResult buildResult({
      required bool success,
      required SynthesisTerminationReason reason,
      String? failedSymbol,
    }) {
      // Where execution actually got to — the most recent function the
      // firmware entered. Read here (before the finally-block reset) so
      // it is valid on EVERY exit path, including the clean-timeout
      // success where no pause fires and `lastPauseSymbol` is stale.
      final finalExecutionSymbol = emulationController.lastExecutedSymbol;
      final recentExecutionTrace = emulationController.recentExecutionTrace;
      closeIteration(iteration);
      final manifest = buildManifest(
        elfHash: elfHash,
        elfFileName: elfFileName,
        runId: runId,
        success: success,
        totalIterations: iteration,
        duration: stopwatch.elapsed,
        failedSymbol: failedSymbol,
        attempts: attempts,
        lastPauseSymbol: lastObservedPauseSymbol,
        terminationReason: reason,
        finalExecutionSymbol: finalExecutionSymbol,
        recentExecutionTrace: recentExecutionTrace,
        timing: List.unmodifiable(iterationTimings),
        stops: List.unmodifiable(stops),
        phaseTimings: PhaseTimings(
          selectionSeconds: selectionWatch.elapsed.inMilliseconds / 1000.0,
          generationSeconds: generationWatch.elapsed.inMilliseconds / 1000.0,
        ),
      );
      return SynthesizerResult(
        success: success,
        totalIterations: iteration,
        resolvedHooks: Map.unmodifiable(hookMap),
        resolvedHookCode: Map.unmodifiable(buildHookCodeMap()),
        failedSymbol: failedSymbol,
        lastPauseSymbol: lastObservedPauseSymbol,
        terminationReason: reason,
        finalExecutionSymbol: finalExecutionSymbol,
        recentExecutionTrace: recentExecutionTrace,
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
            ManifestAttempt(
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
          ManifestAttempt(
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
            ManifestAttempt(
              code: entry.value,
              kind: ManifestDecisionKind.warmStart,
              source: 'warm_start',
            ));
        print('[Synthesizer] Pre-seeded resolved hook for "${entry.key}"');
      }
    }

    // Pre-seed object groups the LLM (or user) marked `forced` — install the
    // whole object proactively, before any member faults. On-fault escalation
    // still handles the rest; suppressed groups are skipped there.
    for (final plan in forcedGroupPlans(
      symbolGroups: symbolGroups,
      groupOverrides: groupOverrides,
      appliedScopes: appliedGroupScopes,
      overriddenSymbols: overriddenSymbols,
    )) {
      installGroupPlan(plan);
      print('[Synthesizer] Pre-seeded forced object group "${plan.scope}" '
          '(${plan.members.length} member hook(s))');
    }

    try {
      while (iteration < maxIterations && _isRunning) {
        closeIteration(iteration);
        iteration++;
        currentIterStart = stopwatch.elapsed;

        _eventController.add(SynthesizerIterationStarted(
          iteration: iteration,
          currentHookMap: Map.unmodifiable(hookMap),
        ));

        print('[Synthesizer] Iteration $iteration — ${hookMap.length} hooks applied');

        // Reset state and reload firmware for a clean CPU state on every
        // iteration (including the first) — emulationWorkflow.start() may
        // have already paused execution mid-firmware.
        await _renodeOp('reset', emulationController.reset);
        await Future.delayed(const Duration(milliseconds: 500));
        await _loadFirmwareWithRetry(baseImagePath, elfPath);

        if (memoryMapPath != null && memoryMapPath.isNotEmpty) {
          await _renodeOp('loadMemoryMap',
              () => emulationController.loadMemoryMap(memoryMapPath));
        }

        // (Re)define all hook code (including pre-seeded overrides on iter 1)
        for (final entry in definedHooks.entries) {
          await _renodeOp(
            'defineHook ${entry.key}',
            () => emulationController.defineHook(
              entry.key,
              entry.value,
              scope: hookScopes[entry.key],
            ),
          );
        }

        if (hookMap.isNotEmpty) {
          await _renodeOp(
              'mapHooks', () => emulationController.mapHooks(hookMap));
        }

        final pauseEvent = await _startAndWaitForPause(
          startFrom: startFrom,
          endAt: endAt,
          pauseOnUnhandled: true,
        );

        if (pauseEvent == null) {
          // Firmware ran cleanly — success.
          stops.add(StopTiming(
            elapsedSeconds: stopwatch.elapsed.inMilliseconds / 1000.0,
            kind: 'clean_exit',
          ));
          stopwatch.stop();
          final result = buildResult(
            success: true,
            reason: SynthesisTerminationReason.cleanRun,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        if (pauseEvent.unhandledAccess != true || pauseEvent.symbol == null) {
          print('[Synthesizer] Non-unhandled pause at ${pauseEvent.symbol}, '
              'waiting for resume...');
          stops.add(StopTiming(
            elapsedSeconds: stopwatch.elapsed.inMilliseconds / 1000.0,
            kind: 'pause',
            symbol: pauseEvent.symbol,
          ));
          await _waitForResumeOrReset();
          continue;
        }

        final symbol = pauseEvent.symbol!;
        lastObservedPauseSymbol = symbol;
        stops.add(StopTiming(
          elapsedSeconds: stopwatch.elapsed.inMilliseconds / 1000.0,
          kind: 'unhandled_access',
          symbol: symbol,
        ));
        print('[Synthesizer] Unhandled access at symbol: $symbol');

        // Forced override that failed: bail out, don't try alternatives.
        if (overriddenSymbols.contains(symbol)) {
          print('[Synthesizer] Symbol "$symbol" has a forced override that failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(
            success: false,
            failedSymbol: symbol,
            reason: SynthesisTerminationReason.forcedOverrideFailed,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        // Object-group escalation (deterministic, at most once per group):
        // the first time any member of a recognized group faults,
        // force-install the coherent hook for every member of that group
        // with the shared scope, then re-run. The decision is a pure
        // function (`planGroupOverride`) so it can be unit-tested without
        // the engine; here we apply its plan. Members with a user override
        // or comms hook are excluded, and a member with no recognized role
        // has no hook and is left to normal per-symbol handling.
        selectionWatch.start();
        final groupPlan = planGroupOverride(
          faultSymbol: symbol,
          groupOf: groupOf,
          appliedScopes: appliedGroupScopes,
          overriddenSymbols: overriddenSymbols,
          suppressedScopes: suppressedGroupScopes,
        );
        selectionWatch.stop();
        if (groupPlan != null) {
          installGroupPlan(groupPlan);
          print('[Synthesizer] Object group "${groupPlan.scope}" — '
              'force-applied ${groupPlan.members.length} member hook(s) '
              'after "$symbol" faulted');
          continue;
        }

        // Effective score for a candidate under THIS symbol: the
        // per-project binding's fidelity when the binding points at
        // the artifact, else the artifact's global intrinsic floor.
        // Hoisted to per-symbol scope (recomputed each iteration, so
        // it sees bindings the LLM fallback adds mid-run) so both the
        // candidate sort AND the LLM-engage gate below use the same
        // scoring.
        final binding = activeBindings[symbol];
        double scoreFor(Artifact a) {
          if (binding != null && binding.artifactId == a.id) {
            return binding.fidelity;
          }
          return a.intrinsicScore ?? 0.0;
        }

        selectionWatch.start();
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
        selectionWatch.stop();

        if (hooks.isEmpty) {
          print('[Synthesizer] ERROR: No hooks found for "$symbol" — '
              'artifact DB registration may have failed');
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(
            success: false,
            failedSymbol: symbol,
            reason: SynthesisTerminationReason.symbolExhausted,
          );
          _eventController.add(SynthesizerCompleted(
            iteration: iteration,
            result: result,
          ));
          return result;
        }

        final currentIndex = hookIndex[symbol] ?? 0;
        final atExhaustion = currentIndex >= hooks.length;

        // Engage the LLM as soon as no SPECIALIZED candidate (score >=
        // _kLlmEngageMinScore — a classifier binding or user artifact)
        // remains to try for this symbol, rather than waiting for the
        // whole DB to be exhausted. Waiting for exhaustion made the
        // fallback unreachable: a symbol's candidate list is the whole
        // artifact DB (~17), larger than the iteration cap (10), so a
        // hard symbol hit MAX_ITERATIONS before the LLM was ever asked.
        // Generics (score < threshold) are still tried, but only as a
        // last resort AFTER the LLM (the LLM's authored hook seeds a
        // 0.5 binding and sorts to the front on the retry). Once the
        // LLM has been tried for this symbol, we fall through to those
        // remaining generics, then to symbol-exhausted failure.
        final specializedOut = specializedCandidatesExhausted(
          nextIndex: currentIndex,
          scoresDesc: [for (final a in hooks) scoreFor(a)],
          minScore: _kLlmEngageMinScore,
        );
        if (specializedOut &&
            llmGenerator != null &&
            !triedLlm.contains(symbol)) {
          triedLlm.add(symbol);
          generationWatch.start();
          final llmBinding = await _tryLlmFallback(
            symbol: symbol,
            iteration: iteration,
            elfHash: elfHash,
            llmGenerator: llmGenerator,
            platform: platform,
          );
          generationWatch.stop();
          if (llmBinding != null) {
            activeBindings[symbol] = llmBinding;
            // Clear the per-symbol cache so the next iteration
            // re-queries with the new artifact in the candidate
            // list. Reset the hookIndex so the fresh sort starts
            // from index 0 (the authored hook sorts to the front).
            hookCache.remove(symbol);
            hookIndex.remove(symbol);
            continue;
          }
          // Generation failed (empty output, network error, etc.) —
          // fall through to any remaining generic candidates below.
        }

        if (atExhaustion) {
          stopwatch.stop();
          _eventController.add(SynthesizerSymbolExhausted(
            iteration: iteration,
            symbol: symbol,
          ));
          final result = buildResult(
            success: false,
            failedSymbol: symbol,
            reason: SynthesisTerminationReason.symbolExhausted,
          );
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
        // chosen artifact; iteration_fallback otherwise. `binding` is
        // the per-symbol binding hoisted above.
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
            ManifestAttempt(
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
      // Reached the iteration cap (or was cancelled). This is a
      // control-flow outcome, NOT a fault at a symbol — record it as a
      // termination reason and leave failedSymbol null so nothing
      // downstream mistakes the sentinel for a hookable symbol.
      final result = buildResult(
        success: false,
        reason: _isRunning
            ? SynthesisTerminationReason.maxIterations
            : SynthesisTerminationReason.cancelled,
      );
      _eventController.add(SynthesizerCompleted(
        iteration: iteration,
        result: result,
      ));
      return result;
    } finally {
      // Best-effort cleanup; control channel may already be disconnected
      // or wedged — bound it so teardown can't hang either.
      try {
        await emulationController.reset().timeout(_kRenodeOpTimeout);
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
      await _renodeOp(
        'start',
        () => emulationController.start(
          startFrom: startFrom,
          endAt: endAt,
          pauseOnUnhandled: pauseOnUnhandled,
        ),
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

  /// Run a single Renode control round-trip under [_kRenodeOpTimeout].
  /// On expiry throws [SynthesizerException] so the run aborts (and the
  /// caller writes a report) instead of blocking forever on an
  /// unresponsive engine. See [_kRenodeOpTimeout].
  Future<T> _renodeOp<T>(String what, Future<T> Function() op) async {
    try {
      return await op().timeout(_kRenodeOpTimeout);
    } on TimeoutException {
      throw SynthesizerException(
          'Renode "$what" did not respond within '
          '${_kRenodeOpTimeout.inSeconds}s — engine unresponsive; '
          'aborting run.');
    }
  }

  Future<void> _loadFirmwareWithRetry(String baseImagePath, String elfPath) async {
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 2);

    Object? lastError;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await _renodeOp(
            'load', () => emulationController.load(baseImagePath, elfPath));
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


/// Exception thrown when synthesizer operations fail.
class SynthesizerException implements Exception {
  final String message;

  SynthesizerException(this.message);

  @override
  String toString() => 'SynthesizerException: $message';
}

/// One member's slot in a [GroupOverridePlan].
typedef GroupOverrideMember = ({String symbol, String code, String? scope});

/// The set of member hooks to force-install when an object group escalates.
class GroupOverridePlan {
  const GroupOverridePlan({required this.scope, required this.members});

  /// The group's shared scope (its key, e.g. `LL_RCC_LSI`).
  final String scope;

  /// The members to hook, each with its coherent code and the shared scope.
  final List<GroupOverrideMember> members;
}

/// The hookable members of [group] to install, excluding any that already have
/// a user override or comms hook ([overriddenSymbols]). Pure; shared by the
/// forced pre-seed and the on-fault escalation.
List<GroupOverrideMember> groupMemberInstalls(
  SymbolGroup group,
  Set<String> overriddenSymbols,
) {
  final members = <GroupOverrideMember>[];
  for (final entry in group.hookableMembers) {
    if (overriddenSymbols.contains(entry.key)) continue;
    members.add((
      symbol: entry.key,
      code: entry.value.code,
      scope: entry.value.scope,
    ));
  }
  return members;
}

/// Groups the LLM (or user) marked `forced`, to pre-install at run start.
/// Skips groups already applied and those with no installable members. Pure.
List<GroupOverridePlan> forcedGroupPlans({
  required List<SymbolGroup> symbolGroups,
  required Map<String, GroupOverrideState> groupOverrides,
  required Set<String> appliedScopes,
  required Set<String> overriddenSymbols,
}) {
  final plans = <GroupOverridePlan>[];
  for (final group in symbolGroups) {
    if (groupOverrides[group.scope] != GroupOverrideState.forced) continue;
    if (appliedScopes.contains(group.scope)) continue;
    final members = groupMemberInstalls(group, overriddenSymbols);
    if (members.isEmpty) continue;
    plans.add(GroupOverridePlan(scope: group.scope, members: members));
  }
  return plans;
}

/// Decide whether a fault at [faultSymbol] should escalate to a whole-object
/// group override, and if so which member hooks to install.
///
/// Pure and engine-free so it can be unit-tested. Returns null when the
/// symbol isn't in a group, the group was already applied this run
/// ([appliedScopes]), the group is [suppressedScopes] (the LLM cleared it),
/// or every hookable member is excluded (a user override or comms hook —
/// [overriddenSymbols]). The caller records the scope in [appliedScopes] and
/// applies the returned hooks.
GroupOverridePlan? planGroupOverride({
  required String faultSymbol,
  required Map<String, SymbolGroup> groupOf,
  required Set<String> appliedScopes,
  required Set<String> overriddenSymbols,
  Set<String> suppressedScopes = const {},
}) {
  final group = groupOf[faultSymbol];
  if (group == null || appliedScopes.contains(group.scope)) return null;
  if (suppressedScopes.contains(group.scope)) return null;
  final members = groupMemberInstalls(group, overriddenSymbols);
  if (members.isEmpty) return null;
  return GroupOverridePlan(scope: group.scope, members: members);
}
