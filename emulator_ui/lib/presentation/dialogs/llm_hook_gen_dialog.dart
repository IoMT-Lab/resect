import 'dart:async';

import 'package:emulator_orchestrator/data/models/target_arch.dart';
import 'package:emulator_orchestrator/services/quality/hook_progress_runner.dart';
import 'package:emulator_orchestrator/services/quality/hook_scorer.dart';
import 'package:emulator_orchestrator/services/quality/hook_static_analyzer.dart';
import 'package:emulator_orchestrator/services/quality/hook_test_harness.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/quality/llm_judge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/config_providers.dart';
import 'hook_test_result_dialog.dart';

/// Two-state dialog that drives one LLM-driven hook generation pass.
///
/// State 1 — [_Prompting]: user enters a natural-language description of
/// the hook they want and clicks Generate.
/// State 2 — [_Streaming]:  tokens stream live into a code editor as
/// Ollama emits them. When the stream ends the actions swap to
/// Accept / Regenerate / Cancel.
///
/// Accept resolves the dialog with the final code body; the Hook DB
/// dialog drops that into its `codeController`. Cancel resolves with
/// null. Regenerate restarts the stream with the (possibly edited)
/// prompt.
class LlmHookGenDialog extends ConsumerStatefulWidget {
  const LlmHookGenDialog({
    required this.targetSymbol,
    super.key,
    this.targetCallers = const [],
    this.targetCallees = const [],
  });

  final String? targetSymbol;
  final List<String> targetCallers;
  final List<String> targetCallees;

  static Future<String?> show(
    BuildContext context, {
    String? targetSymbol,
    List<String> targetCallers = const [],
    List<String> targetCallees = const [],
  }) =>
      showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => LlmHookGenDialog(
          targetSymbol: targetSymbol,
          targetCallers: targetCallers,
          targetCallees: targetCallees,
        ),
      );

  @override
  ConsumerState<LlmHookGenDialog> createState() => _LlmHookGenDialogState();
}

class _LlmHookGenDialogState extends ConsumerState<LlmHookGenDialog> {
  final _promptController = TextEditingController();
  final _codeController = TextEditingController();
  StreamSubscription<String>? _sub;
  var _streaming = false;
  var _done = false;
  String? _error;

  /// Built once at dialog-open from the current Emulator's .repl +
  /// architecture + symbols. Null until the load completes (it's
  /// async because the .repl is read from disk) or when the project
  /// lacks one of the prerequisites — generate() handles null fine.
  PlatformFacts? _platform;

  /// "cached" once we've confirmed the artifact-database has
  /// signatures for this ELF; "building" while a background
  /// extraction is in flight; "none" otherwise. Drives the
  /// dialog's Context line and tells the user whether they're
  /// going to get Ghidra-derived argument storage in the prompt.
  String _signatureCacheStatus = 'none';

  /// Result of the most recent [HookTestHarness.runHook] pass over
  /// the just-generated code. Populated automatically when the
  /// token stream finishes (the `onDone` handler on `_sub`). Null
  /// while the harness is in flight, before the first run, and
  /// after the user clicks Regenerate (cleared and re-populated
  /// for the new code body).
  HookTestResult? _harnessResult;

  /// True while [HookTestHarness.runHook] is in flight. The inline
  /// status strip shows "Testing in Renode…" during this window.
  /// Set just before the call; cleared in the await's `finally`.
  var _harnessRunning = false;

  /// Set by [_runHarness] when the harness future throws before
  /// producing a result (e.g. Renode binary missing). Distinct
  /// from `_harnessResult.errorMessage` — that field is set when
  /// the harness ran but the hook misbehaved.
  String? _harnessError;

  /// Quality report from the [HookScorer] over the harness result
  /// + the generator's classification verdict. Populated in
  /// [_runHarness] after the harness completes. Null while the
  /// harness is in flight, before the first run, and on regenerate.
  /// May be re-populated when the LLM judge finishes (Layer 3 of
  /// the metric) — the first report has `judgeScore=null`, then
  /// updates in place when [_runJudgeAsync] resolves.
  HookQualityReport? _qualityReport;

  /// True while the LLM judge is in flight (LLM-path hooks only).
  /// Drives the "Judge in flight…" sub-line in the score strip.
  var _judgeRunning = false;

  /// True while [HookProgressRunner] is in flight. Two Renode boots
  /// in series (with-hook + baseline) take ~15-25 s total; the
  /// strip surfaces this as "progress: measuring (~20s)…" so the
  /// user knows why the score is provisional.
  var _progressRunning = false;

  /// Cached progress-runner result. The dialog's strip uses it via
  /// [_qualityReport]; held here so it can be folded into both the
  /// initial post-harness report and the post-judge re-score.
  HookProgressResult? _progressResult;

  /// Cached judge result. Mirror of [_progressResult]: both async
  /// layers stash their outputs here so the rescorer can fold
  /// whichever has completed.
  LlmJudgeResult? _judgeResult;

  /// Inputs captured at harness-completion time so the async
  /// re-scoring helpers don't need them re-threaded. Cleared on
  /// regenerate.
  HookTestResult? _cachedHarness;
  StaticCheckResult? _cachedStatic;

  @override
  void initState() {
    super.initState();
    // Pre-fill the prompt only when we have a target symbol. The
    // copy below asks for *behaviorally accurate* output — the LLM
    // is supposed to use the RAG-retrieved docs (datasheets,
    // headers) to set the registers/flags a real successful call
    // would set, not just `return 0`. That's the value-add over the
    // catalog's deterministic returnHook(0). For Reusable hooks (no
    // target) we leave the field empty: there's no name to seed
    // from, and the user has to articulate intent.
    final target = widget.targetSymbol;
    if (target != null) {
      _promptController.text = _defaultStubPrompt(target);
    }
    // Kick off platform-facts load. Reading the .repl file is cheap
    // (~50 lines), but it's still async file I/O so we don't block
    // initState. The user can start typing immediately; if they hit
    // Generate before this finishes, the call sees _platform == null
    // and just skips the ## Platform section instead of waiting.
    unawaited(_loadPlatformFacts());
    // Same idea for the Ghidra signature cache: probe (and, if
    // enabled-but-empty, kick off) extraction asynchronously. The
    // first generation may go without; subsequent ones will pick up
    // the cached signature once Ghidra finishes (~30 s-2 min).
    unawaited(_primeSignatureCache());
  }

  Future<void> _loadPlatformFacts() async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null) return;
    // FirmwareRecord.machine is the authoritative arch — set by the
    // artifact-processing pipeline when the ELF is first parsed.
    // Pre-v5 .emu files don't have it; PlatformFacts.tryBuild
    // returns null in that case and the dialog generates without
    // a ## Platform block.
    final arch =
        ref.read(artifactProcessingProvider).valueOrNull?.machine?.name;
    final facts = await PlatformFacts.tryBuild(
      replPath: emulator.baseImagePath,
      archString: arch,
      firmwareSymbols: emulator.cachedCallGraph?.symbols.keys ?? const [],
    );
    if (!mounted) return;
    setState(() => _platform = facts);
  }

  Future<void> _primeSignatureCache() async {
    final ghidraEnabled =
        ref.read(moduleEnabledProvider('MODULE_GHIDRA'));
    if (!ghidraEnabled) return;
    final emulator = ref.read(currentEmulatorProvider);
    final elfPath = emulator?.elfFilePath;
    final elfHash =
        ref.read(artifactProcessingProvider).valueOrNull?.elfHash;
    if (elfPath == null || elfHash == null || emulator == null) return;
    final service = ref.read(signaturesServiceProvider);
    // Gate on `hasCompleteGhidraExtractionFor` — true iff the
    // *new* (schema-v8) `ghidra_decompilations` table has rows.
    // `hasSignaturesFor` alone returns true for stale pre-v8
    // caches whose new tables are empty, and we'd silently feed
    // the LLM zero decompilation chunks. See
    // [signatures_service.dart:hasCompleteGhidraExtractionFor].
    final hasFullCache =
        await service.hasCompleteGhidraExtractionFor(elfHash);
    if (hasFullCache) {
      if (!mounted) return;
      setState(() => _signatureCacheStatus = 'cached');
      return;
    }
    if (!mounted) return;
    setState(() => _signatureCacheStatus = 'building signatures');
    try {
      await for (final _ in service.extractFor(elfPath)) {
        // Drain — per-event progress isn't surfaced in this
        // dialog. The phase label already changed to 'building
        // signatures' above; the next phase change happens after
        // extraction finishes.
      }
      // After extraction populates all six Ghidra tables, the
      // per-project RAG index needs a rebuild to embed the new
      // decompilation / data_type / data_symbol / memory_section
      // chunks. Without this chained rebuild the user has the
      // data in the artifact DB but the LLM dialog's cosine
      // retrieval finds nothing under those kinds — exactly the
      // gap the LL_APB0_GRP1_EnableClock generation hit.
      final ragIndex = ref.read(ragIndexProvider);
      if (ragIndex != null) {
        if (!mounted) return;
        setState(() => _signatureCacheStatus = 'building rag');
        await for (final _ in ragIndex.rebuildFor(
          emulator,
          elfHash: elfHash,
        )) {
          // Drain.
        }
      }
      if (!mounted) return;
      setState(() => _signatureCacheStatus = 'cached');
      // Refresh the FutureProvider so a subsequent Generate picks
      // up the freshly-extracted signature for this target.
      final target = widget.targetSymbol;
      if (target != null) {
        ref.invalidate(signatureForProvider(target));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _signatureCacheStatus = 'none');
    }
  }

  /// The pre-fill / fallback prompt text for a Replacement hook on
  /// [target]. Substitute framing — the goal is to make the
  /// caller continue without unhandled memory accesses, NOT to
  /// reproduce the function's hardware operations. Replicating
  /// peripheral writes either crashes the emulator (unmapped
  /// MMIO) or wastes I/O (mapped but Renode doesn't care about
  /// the bits).
  static String _defaultStubPrompt(String target) =>
      'Substitute for $target in emulation. The goal is to let the '
      'caller continue without generating unhandled memory accesses — '
      'NOT to reproduce what the real hardware would do. Read the '
      'decompilation only to learn (a) what $target returns and (b) '
      'whether it writes to any caller-provided pointer buffers. If '
      "it's purely hardware-touching with no outputs, the hook is "
      'just setReturnValue(cpu, 0).';

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _promptController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _start() {
    final prompt = _promptController.text.trim();
    final target = widget.targetSymbol;
    // Empty submission is only sensible with a target symbol — the
    // ## Target section then carries the intent. Without a target
    // there's nothing for the model to work with. We also point at
    // the catalog explicitly: simple return/read/write hooks
    // shouldn't roundtrip through the LLM at all.
    if (prompt.isEmpty && target == null) {
      setState(() => _error =
          'Describe behavior beyond a simple return value, or pick '
          'a target symbol. For trivial return/read/write stubs use '
          '"Insert starter template" instead — it produces the same '
          'output the catalog already generates, no LLM needed.');
      return;
    }
    final generator = ref.read(llmHookGeneratorProvider);
    if (generator == null) {
      setState(() => _error = 'Open and save a project before generating.');
      return;
    }
    setState(() {
      _streaming = true;
      _done = false;
      _error = null;
      _codeController.clear();
      // Clear any prior harness result/error/score — they belong
      // to the previous generation, not the one we're about to
      // start. The status strip hides until the next run
      // completes.
      _harnessResult = null;
      _harnessError = null;
      _harnessRunning = false;
      _qualityReport = null;
      _judgeRunning = false;
      _progressRunning = false;
      _progressResult = null;
      _judgeResult = null;
      _cachedHarness = null;
      _cachedStatic = null;
    });
    // Empty + target is allowed (see _start guard above); fall back
    // to the same pre-fill copy the dialog opened with so the model
    // sees the behavior-accurate-stub instruction rather than a
    // trivial "return success".
    final userPrompt = prompt.isEmpty ? _defaultStubPrompt(target!) : prompt;
    // Cache lookup only — never triggers extraction here. If the
    // Ghidra module isn't installed / hasn't been run for this ELF,
    // the provider returns null and the prompt falls back to the
    // generic ABI guidance baked into the system prompt.
    final signature = widget.targetSymbol == null
        ? null
        : ref.read(signatureForProvider(widget.targetSymbol!)).valueOrNull;
    // Per-arch ABI block for the prompt — derived from the loaded
    // ELF's e_machine (via FirmwareRecord.machine). Null when no
    // entry exists in the registry; the prompt then uses just the
    // signature info (if any) and falls back to the system prompt's
    // generic guidance.
    final firmware = ref.read(artifactProcessingProvider).valueOrNull;
    final targetArch = targetArchFor(firmware?.machine);
    // ELF hash is what `LlmHookGenerator` uses to look up the
    // target's pinned `decompilation` chunk from the artifact DB.
    // Null when no firmware is loaded — generator falls back to
    // plain cosine-ranked retrieval.
    final elfHash = firmware?.elfHash;
    _sub = generator
        .generate(
      userPrompt: userPrompt,
      targetSymbol: widget.targetSymbol,
      elfHash: elfHash,
      targetCallers: widget.targetCallers,
      targetCallees: widget.targetCallees,
      platform: _platform,
      signature: signature,
      targetArch: targetArch,
    )
        .listen(
      (token) {
        _codeController.text += token;
        _codeController.selection = TextSelection.collapsed(
          offset: _codeController.text.length,
        );
      },
      onError: (Object e) {
        setState(() {
          _streaming = false;
          _done = true;
          _error = '$e';
        });
      },
      onDone: () {
        setState(() {
          _streaming = false;
          _done = true;
        });
        // Auto-run the just-generated hook through the existing
        // HookTestHarness. The bundled minimal-.repl rig
        // discriminates substitute-style hooks (don't touch
        // hardware) from replication attempts (do touch hardware →
        // unhandled access fires). Same path the Hook DB dialog's
        // Test button uses, just kicked off without a button click.
        unawaited(_runHarness());
      },
    );
  }

  /// Runs the current code-editor contents through
  /// [HookTestHarness.runHook], then through [HookScorer] together
  /// with the generator's most recent classification verdict.
  /// Updates [_harnessResult], [_harnessError], [_harnessRunning],
  /// and [_qualityReport] so the inline status strip + score
  /// breakdown re-render.
  ///
  /// The classification verdict comes from
  /// `generator.lastClassification` — non-null when the classifier
  /// matched and produced a catalog hook; null when the LLM path
  /// was used. The scorer uses it to evaluate the invariant
  /// against the harness's 10 captured returns (the gate-level
  /// check that catches things like HAL_GetTick → 0).
  Future<void> _runHarness() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _harnessRunning = true;
      _harnessResult = null;
      _harnessError = null;
      _qualityReport = null;
    });
    final harness = ref.read(hookTestHarnessProvider);
    final generator = ref.read(llmHookGeneratorProvider);
    try {
      final result = await harness.runHook(hookCode: code);
      if (!mounted) return;
      // Static analysis: mod-set containment + unmapped-access
      // budget. Needs the original's decompilation + parameter
      // names + the project's .repl. We already have those on hand
      // (the dialog loaded the platform facts in initState; the
      // signature came in for the generator's classifier).
      final staticResult = await _maybeRunStaticAnalysis(
        candidateCode: code,
      );
      final report = const HookScorer().score(
        harness: result,
        classification: generator?.lastClassification,
        staticResult: staticResult,
      );
      setState(() {
        _harnessResult = result;
        _qualityReport = report;
        _harnessRunning = false;
        _cachedHarness = result;
        _cachedStatic = staticResult;
      });
      // Kick off the LLM judge asynchronously for LLM-path hooks
      // that passed the gate. Classifier-fired hooks short-circuit
      // to Layer 3 = 1.0 in the scorer (catalog template is
      // correct by construction; judging it is circular).
      if (report.gatePassed &&
          generator?.lastClassification == null) {
        unawaited(_runJudgeAsync(
          candidateCode: code,
          harness: result,
          staticResult: staticResult,
        ));
      }
      // Kick off the progress runner asynchronously. Layer 2 of
      // the metric — the load-bearing behavioural signal. Runs in
      // parallel with the judge; both will fold into the score
      // when they complete. Fires for any gate-passing hook,
      // including classifier-fired ones (the runner's "with-hook
      // vs baseline" comparison is meaningful regardless of which
      // path produced the hook).
      if (report.gatePassed) {
        unawaited(_runProgressAsync(
          candidateCode: code,
          harness: result,
          staticResult: staticResult,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _harnessError = '$e';
        _harnessRunning = false;
      });
    }
  }

  /// Runs the LLM-as-judge (Layer 3 of the metric) in the
  /// background. Updates [_qualityReport] in place when it
  /// completes so the score strip refreshes. Catches exceptions
  /// (Ollama unreachable, model not loaded, etc.) and reports them
  /// as `_judgeRunning = false` without a score update — the gate-
  /// pass baseline of 1.0 stays.
  ///
  /// Baseline: the canonical no-op substitute (the 2-line
  /// `setReturnValue(cpu, 0)`). The judge picks whether the LLM's
  /// richer hook beats that baseline for the function's contract.
  Future<void> _runJudgeAsync({
    required String candidateCode,
    required HookTestResult harness,
    required StaticCheckResult? staticResult,
  }) async {
    final target = widget.targetSymbol;
    if (target == null) return;
    final firmware = ref.read(artifactProcessingProvider).valueOrNull;
    final elfHash = firmware?.elfHash;
    if (elfHash == null) return;
    final db = ref.read(artifactDatabaseProvider);
    final decompilation = await db.decompilationFor(
      elfHash: elfHash,
      functionName: target,
    );
    if (decompilation == null) return;
    final client = ref.read(llmClientProvider);
    final judge = LlmJudge(client: client);

    if (mounted) setState(() => _judgeRunning = true);
    try {
      final verdict = await judge.evaluate(
        candidateHook: candidateCode,
        baselineHook: _kBaselineSubstitute,
        functionName: target,
        decompilation: decompilation,
      );
      if (!mounted) return;
      setState(() {
        _judgeResult = verdict;
        _judgeRunning = false;
      });
      _rescoreFromCachedLayers();
    } catch (_) {
      if (!mounted) return;
      setState(() => _judgeRunning = false);
    }
  }

  /// Runs [HookProgressRunner] in the background (Layer 2 of the
  /// metric — emulator-progress signal). Two Renode boots in
  /// series; ~15-25 s total. On completion, folds the result into
  /// [_qualityReport] via [_rescoreFromCachedLayers] so the score
  /// strip refreshes with the (weight 0.6) progress contribution.
  Future<void> _runProgressAsync({
    required String candidateCode,
    required HookTestResult harness,
    required StaticCheckResult? staticResult,
  }) async {
    final target = widget.targetSymbol;
    if (target == null) return;
    final emulator = ref.read(currentEmulatorProvider);
    final replPath = emulator?.baseImagePath;
    final elfPath = emulator?.elfFilePath;
    if (replPath == null || elfPath == null) return;
    final runner = HookProgressRunner();

    if (mounted) setState(() => _progressRunning = true);
    try {
      final result = await runner.measure(
        replPath: replPath,
        elfPath: elfPath,
        targetSymbol: target,
        hookCode: candidateCode,
      );
      if (!mounted) return;
      setState(() {
        _progressResult = result;
        _progressRunning = false;
      });
      _rescoreFromCachedLayers();
    } catch (_) {
      if (!mounted) return;
      setState(() => _progressRunning = false);
    }
  }

  /// Re-build [_qualityReport] from the latest cached layers. Used
  /// by [_runJudgeAsync] / [_runProgressAsync] when their async
  /// results land; idempotent and safe to call from either order
  /// of completion.
  void _rescoreFromCachedLayers() {
    final harness = _cachedHarness;
    if (harness == null) return;
    final generator = ref.read(llmHookGeneratorProvider);
    final updated = const HookScorer().score(
      harness: harness,
      classification: generator?.lastClassification,
      staticResult: _cachedStatic,
      judgeResult: _judgeResult,
      progressResult: _progressResult,
    );
    setState(() => _qualityReport = updated);
  }

  /// Baseline hook the LLM judge compares the candidate against:
  /// the bare-minimum no-op substitute. If the candidate doesn't
  /// beat this, the candidate isn't adding value.
  static const String _kBaselineSubstitute =
      'import set_return_value\nsetReturnValue(cpu, 0)\n';

  /// Run [HookStaticAnalyzer] when we have everything it needs
  /// (target symbol + decompilation + .repl content). Returns null
  /// when any input is missing — the scorer treats null as "skip
  /// these checks" and surfaces only the harness + invariant gates.
  Future<StaticCheckResult?> _maybeRunStaticAnalysis({
    required String candidateCode,
  }) async {
    final target = widget.targetSymbol;
    if (target == null) return null;
    final platform = _platform;
    if (platform == null) return null;
    final firmware = ref.read(artifactProcessingProvider).valueOrNull;
    final elfHash = firmware?.elfHash;
    if (elfHash == null) return null;
    final db = ref.read(artifactDatabaseProvider);
    final decompilation = await db.decompilationFor(
      elfHash: elfHash,
      functionName: target,
    );
    if (decompilation == null) return null;
    final sig = ref.read(signatureForProvider(target)).valueOrNull;
    final paramNames = sig?.parameters.map((p) => p.name).toList() ?? const <String>[];
    return const HookStaticAnalyzer().evaluate(
      candidateCode: candidateCode,
      originalDecompilation: decompilation,
      parameterNames: paramNames,
      replContent: platform.replContent,
    );
  }

  Future<void> _cancelStream() async {
    await _sub?.cancel();
    _sub = null;
    setState(() {
      _streaming = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final llmEnabled = ref.watch(moduleEnabledProvider('MODULE_LLM_HOOKGEN'));
    return Dialog(
      backgroundColor: AppTheme.bgPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(targetSymbol: widget.targetSymbol),
            const Divider(height: 1, color: AppTheme.border),
            if (!llmEnabled)
              const _NotInstalledNotice()
            else
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Three lines of context above the prompt:
                      //   1. Platform summary → what's being fed in
                      //      from .repl + arch + symbols, so the
                      //      user sees the LLM isn't guessing.
                      //   2. RAG empty → tell the user the behavior-
                      //      accurate stub won't have much to chew
                      //      on without an index built.
                      //   3. Catalog hint → for trivial cases the
                      //      starter template is the right path.
                      if (_platform != null) ...[
                        _AdvisoryLine(
                          icon: Icons.memory,
                          color: AppTheme.textMuted,
                          text: 'Context: ${_platform!.summary()} · '
                              'signatures: $_signatureCacheStatus',
                        ),
                        const SizedBox(height: 6),
                      ],
                      _Advisories(streaming: _streaming),
                      const SizedBox(height: 12),
                      _PromptField(
                        controller: _promptController,
                        enabled: !_streaming,
                      ),
                      const SizedBox(height: 12),
                      Flexible(
                        child: _CodeView(
                          controller: _codeController,
                          streaming: _streaming,
                          done: _done,
                        ),
                      ),
                      // Renode-harness result strip: shows the
                      // pass/partial/fail signal from the same path
                      // the Hook DB Test button uses, automatically
                      // run as soon as generation finishes. Hidden
                      // until either the harness is in flight or has
                      // produced a result for the current code body.
                      _HarnessStrip(
                        running: _harnessRunning,
                        result: _harnessResult,
                        error: _harnessError,
                        quality: _qualityReport,
                        judgeRunning: _judgeRunning,
                        progressRunning: _progressRunning,
                        codeLabel: widget.targetSymbol ?? 'generated hook',
                        onRerun: _harnessRunning ||
                                _codeController.text.trim().isEmpty
                            ? null
                            : _runHarness,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Color(0xFFE57373),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const Divider(height: 1, color: AppTheme.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: _ActionRow(
                streaming: _streaming,
                done: _done,
                hasCode: _codeController.text.trim().isNotEmpty,
                onCancel: () => Navigator.of(context).pop(),
                onStop: _cancelStream,
                onGenerate: _start,
                onRegenerate: _start,
                onAccept: () =>
                    Navigator.of(context).pop(_codeController.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String? targetSymbol;
  const _Header({required this.targetSymbol});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome,
                size: 18, color: AppTheme.textPrimary),
            const SizedBox(width: 10),
            const Text(
              'GENERATE HOOK WITH LLM',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(width: 16),
            if (targetSymbol != null)
              Flexible(
                child: Text(
                  'Target: $targetSymbol',
                  style: const TextStyle(
                      color: AppTheme.textMuted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              color: AppTheme.textMuted,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
}

class _NotInstalledNotice extends StatelessWidget {
  const _NotInstalledNotice();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'The LLM Hook Generation module is not enabled. Open Tools → '
          'System Configuration → Modules and install it to use this '
          'feature.',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        ),
      );
}

/// Two advisory lines above the prompt field:
///   1. A reminder that simple stubs belong in the catalog, not the LLM.
///   2. (Conditional) an "⚠ RAG index is empty" warning when the
///      project's RAG index has zero chunks — the behavior-accurate
///      stub copy leans on RAG, so an empty index materially weakens
///      the output and the user should know.
/// Hidden while streaming so the dialog reads as a single conversation.
class _Advisories extends ConsumerWidget {
  final bool streaming;
  const _Advisories({required this.streaming});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (streaming) return const SizedBox.shrink();
    final status = ref.watch(ragIndexStatusProvider);
    final showRagWarning = status.chunkCount == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _AdvisoryLine(
          icon: Icons.info_outline,
          color: AppTheme.textMuted,
          text: 'For trivial return/read/write stubs, use "Insert '
              'starter template" in the Hook DB instead — no LLM '
              'roundtrip, deterministic output.',
        ),
        if (showRagWarning) ...[
          const SizedBox(height: 6),
          const _AdvisoryLine(
            icon: Icons.warning_amber_rounded,
            color: Color(0xFFFFB74D),
            text: 'RAG index is empty — generation will rely only on '
                'the target symbol name and the system prompt. '
                'Rebuild the index from the Library tab for richer '
                'context.',
          ),
        ],
      ],
    );
  }
}

class _AdvisoryLine extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _AdvisoryLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 13, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      );
}

class _PromptField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  const _PromptField({required this.controller, required this.enabled});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Describe what the hook should do',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: enabled,
            maxLines: 3,
            minLines: 2,
            style: const TextStyle(
                color: AppTheme.textPrimary, fontSize: 12),
            decoration: InputDecoration(
              filled: true,
              fillColor: AppTheme.bgCanvas,
              isDense: true,
              hintText:
                  'e.g. Pretend the oscillator started successfully — '
                  'return HAL_OK (0).',
              hintStyle: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: AppTheme.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: const BorderSide(color: AppTheme.border),
              ),
            ),
          ),
        ],
      );
}

class _CodeView extends StatelessWidget {
  final TextEditingController controller;
  final bool streaming;
  final bool done;
  const _CodeView({
    required this.controller,
    required this.streaming,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    final label = streaming
        ? 'Generating…'
        : done
            ? 'Generated code (editable)'
            : 'Output';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (streaming)
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.4),
              ),
            if (streaming) const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.bgCanvas,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: controller,
              maxLines: null,
              expands: true,
              readOnly: streaming,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.4,
              ),
              decoration: const InputDecoration.collapsed(hintText: ''),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final bool streaming;
  final bool done;
  final bool hasCode;
  final VoidCallback onCancel;
  final VoidCallback onStop;
  final VoidCallback onGenerate;
  final VoidCallback onRegenerate;
  final VoidCallback onAccept;

  const _ActionRow({
    required this.streaming,
    required this.done,
    required this.hasCode,
    required this.onCancel,
    required this.onStop,
    required this.onGenerate,
    required this.onRegenerate,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    if (streaming) {
      return Row(
        children: [
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop, size: 14),
            label: const Text('Stop'),
            style: _outline,
          ),
        ],
      );
    }
    if (done && hasCode) {
      return Row(
        children: [
          OutlinedButton(
            onPressed: onCancel,
            style: _outline,
            child: const Text('Cancel'),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: onRegenerate,
            icon: const Icon(Icons.refresh, size: 14),
            label: const Text('Regenerate'),
            style: _outline,
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onAccept,
            icon: const Icon(Icons.check, size: 14),
            label: const Text('Accept'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        OutlinedButton(
          onPressed: onCancel,
          style: _outline,
          child: const Text('Cancel'),
        ),
        const Spacer(),
        ElevatedButton.icon(
          onPressed: onGenerate,
          icon: const Icon(Icons.play_arrow, size: 14),
          label: const Text('Generate'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accent,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  static final ButtonStyle _outline = OutlinedButton.styleFrom(
    foregroundColor: AppTheme.textPrimary,
    side: const BorderSide(color: AppTheme.border),
  );
}

/// Inline result strip rendered between the code editor and the
/// action row. Reflects three states:
///
/// - **Running** — harness is in flight. Spinner + "Testing in
///   Renode…".
/// - **Pass** (`ranToCompletion=true`, `errorMessage=null`) — green
///   check, "Ran cleanly · 10 calls, $runtime", a Show-details link
///   that opens the existing [HookTestResultDialog].
/// - **Partial** (`ranToCompletion=true` with `errorMessage`) — amber
///   warning. Bootstrap finished but an unhandled access occurred
///   during the run. Quote the message; Show-details for the full
///   dialog.
/// - **Fail** (`ranToCompletion=false`) — red. Bootstrap didn't
///   complete (timeout, crash, harness-launch error). Quote the
///   message; Show-details for the Renode log tail.
/// - **Pre-run / cleared** — empty (returns SizedBox.shrink).
///
/// "Show details" opens the same [HookTestResultDialog] the Hook DB
/// Test button uses — no UI duplication.
class _HarnessStrip extends StatelessWidget {
  final bool running;
  final HookTestResult? result;
  final String? error;
  final HookQualityReport? quality;
  final bool judgeRunning;
  final bool progressRunning;
  final String codeLabel;
  final VoidCallback? onRerun;

  const _HarnessStrip({
    required this.running,
    required this.result,
    required this.error,
    required this.quality,
    required this.judgeRunning,
    required this.progressRunning,
    required this.codeLabel,
    required this.onRerun,
  });

  @override
  Widget build(BuildContext context) {
    if (running) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.textMuted,
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Testing in Renode…',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (error != null) {
      return _strip(
        context: context,
        color: const Color(0xFFE57373),
        icon: Icons.error_outline,
        title: 'Harness failed to launch',
        body: error,
      );
    }
    final r = result;
    if (r == null) return const SizedBox.shrink();

    // When we have a quality report (Stage 1 wiring), it's the
    // authoritative signal: the report's gate sub-checks include
    // the harness check + (when classification fired) the
    // invariant check. A passing harness with a failing invariant
    // (e.g. HAL_GetTick → [0,0,…,0]) reads as gate-fail here.
    final q = quality;
    if (q != null) {
      final ms = r.runtime.inMilliseconds;
      if (q.gatePassed) {
        final scoreStr = q.score.toStringAsFixed(2);
        // Two sub-lines: one for the emulator-progress signal
        // (Layer 2, weight 0.6) and one for the LLM judge
        // (Layer 3, weight 0.3). Each shows in-flight,
        // finished-with-score, or skipped-by-classifier.
        final lines = <String>[];
        if (progressRunning) {
          lines.add('progress: measuring (~20s, two Renode boots)…');
        } else if (q.progressScore != null) {
          lines.add('progress ${q.progressScore!.toStringAsFixed(2)}: '
              '${q.progressDetail ?? ""}');
        }
        if (judgeRunning) {
          lines.add('judge: in flight (LLM, ~60s)…');
        } else if (q.judgeScore != null) {
          lines.add('judge ${q.judgeScore!.toStringAsFixed(2)}: '
              '${q.judgeJustification ?? ""}');
        }
        return _strip(
          context: context,
          color: const Color(0xFF81C784),
          icon: Icons.check_circle_outline,
          title: 'Score $scoreStr  ·  gate passed  ·  '
              '${r.returnValues.length} calls, ${ms}ms'
              '${_classificationSuffix(q)}',
          body: lines.isEmpty ? null : lines.join('\n'),
        );
      }
      return _strip(
        context: context,
        color: const Color(0xFFE57373),
        icon: Icons.error_outline,
        title: 'Score 0.0  ·  gate failed'
            '${_classificationSuffix(q)}',
        body: q.firstViolation,
      );
    }

    // Fallback to the pre-scorer strip when no classification ran.
    // (Used for LLM-path hooks until Rule 8/9 invariants land.)
    final passed = r.ranToCompletion && r.errorMessage == null;
    final partial = r.ranToCompletion && r.errorMessage != null;
    if (passed) {
      final ms = r.runtime.inMilliseconds;
      return _strip(
        context: context,
        color: const Color(0xFF81C784),
        icon: Icons.check_circle_outline,
        title: 'Ran cleanly in Renode  ·  '
            '${r.returnValues.length} calls, ${ms}ms',
        body: null,
      );
    }
    if (partial) {
      return _strip(
        context: context,
        color: const Color(0xFFFFB74D),
        icon: Icons.warning_amber_outlined,
        title: 'Ran with warnings',
        body: r.errorMessage,
      );
    }
    return _strip(
      context: context,
      color: const Color(0xFFE57373),
      icon: Icons.error_outline,
      title: 'Did not complete',
      body: r.errorMessage,
    );
  }

  static String _classificationSuffix(HookQualityReport q) {
    final c = q.classification;
    if (c == null) return '';
    return '  ·  ${c.ruleName} → ${c.templateName}';
  }

  Widget _strip({
    required BuildContext context,
    required Color color,
    required IconData icon,
    required String title,
    required String? body,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                  ),
                  if (result != null)
                    TextButton(
                      onPressed: () => HookTestResultDialog.show(
                        context,
                        hookLabel: codeLabel,
                        result: result!,
                        onRerun: onRerun,
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Show details',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
              if (body != null && body.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      );
}
