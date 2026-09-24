import 'dart:io';

import '../config/env_config.dart';
import '../data/models/chip_identity.dart';
import '../data/repositories/emulator_repository.dart';
import '../services/chip/chip_detector.dart';
import '../services/chip/platform_index.dart';
import '../services/corpus/corpus_index.dart';
import '../services/corpus/corpus_service.dart';
import '../services/corpus/vendor_adapter.dart';
import '../services/llm/llm_client.dart';
import '../core/app_paths.dart';

/// Headless corpus operations, sharing ONE code path with the UI so
/// `resect-cli corpus …` and the Fetch button behave identically.
///
/// Commands (dispatched from bin/cli.dart):
///   corpus detect  --emu <p>
///   corpus fetch   [--emu <p> | --chip <part>] [--yes] [--skip-pdf]
///   corpus status  [--emu <p> | --chip <part>]
class CorpusCli {
  CorpusCli({CorpusService? service, LlmClient? client})
      : _service =
            service ?? CorpusService(client: client ?? _defaultClient());

  final CorpusService _service;

  static LlmClient _defaultClient() {
    final cfg = EnvConfig.load();
    final host = (cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
    final model = (cfg.get('LLM_MODEL') ?? '').trim();
    return LlmClient(
      host: host.isEmpty ? 'localhost:11434' : host,
      model: model.isEmpty ? 'gemma4:e4b' : model,
    );
  }

  /// Detect the chip from a project's repl/symbols. Returns a
  /// best-effort identity (may be low confidence / vendor-only).
  Future<ChipIdentity> detectFor({String? emuPath, String? chipOverride}) async {
    if (chipOverride != null) {
      final parsed = ChipNameParser.parse(chipOverride);
      if (parsed == null) {
        throw ArgumentError('Unrecognized chip "$chipOverride"');
      }
      return parsed.copyWith(
        confidence: 1,
        userOverridden: true,
        evidence: [
          ChipEvidence(
              signal: ChipSignal.userOverride,
              detail: 'user --chip $chipOverride',
              weight: 1),
        ],
      );
    }
    if (emuPath == null) {
      throw ArgumentError('Provide --emu <project> or --chip <part>.');
    }
    final emulator = await EmulatorRepository().loadEmulator(emuPath);
    final replPath = emulator.baseImagePath;
    final replContent = (replPath != null && File(replPath).existsSync())
        ? File(replPath).readAsStringSync()
        : null;

    List<PlatformMatch> matches = const [];
    if (replContent != null) {
      try {
        final index = await PlatformIndex.load(
          engineDir: Directory(AppPaths.findEngineDir()),
          cacheFile: File('${AppPaths.corpusDir}/platform_index.json'),
        );
        matches = index.match(replContent);
      } catch (_) {
        // Engine dir absent (installed app) — detection still works
        // from repl content + symbols.
      }
    }
    return ChipDetector.detect(
      replContent: replContent,
      replPath: replPath,
      elfPath: emulator.elfFilePath,
      symbolNames: emulator.cachedCallGraph?.symbols.keys ?? const [],
      platformMatches: matches,
    );
  }

  void printIdentity(ChipIdentity chip) {
    stdout.writeln('Detected chip: ${chip.label}'
        '${chip.corpusKey != null ? '  [${chip.corpusKey}]' : ''}');
    stdout.writeln('  vendor=${chip.vendor}  family=${chip.family}  '
        'part=${chip.part}  core=${chip.core}  '
        'confidence=${chip.confidence.toStringAsFixed(2)}');
    for (final e in chip.evidence) {
      stdout.writeln('  · ${e.signal.name}: ${e.detail}');
    }
  }

  /// Full fetch flow with consent. Returns false if the user declined
  /// or nothing could be planned; throws on fetch failure. [assumeYes]
  /// skips the prompt (non-interactive). [skipPdf] drops PDF items.
  Future<bool> fetch(
    ChipIdentity chip, {
    required bool assumeYes,
    bool skipPdf = false,
  }) async {
    if (chip.corpusKey == null) {
      stderr.writeln('No vendor/family resolved for ${chip.label} — cannot '
          'fetch. Set the exact part with --chip.');
      return false;
    }
    var plan = _service.planFor(chip);
    if (plan == null) {
      stderr.writeln('No curated adapter for ${chip.corpusKey}. '
          'Supported vendors: see docs/pages/chip-corpus.md.');
      return false;
    }
    if (skipPdf) {
      plan = FetchPlan(
        corpusKey: plan.corpusKey,
        chip: plan.chip,
        items: plan.items
            .where((i) =>
                i.kind != CorpusItemKind.datasheetPdf &&
                i.kind != CorpusItemKind.referenceManualPdf)
            .toList(),
        notes: plan.notes,
      );
    }

    _printPlan(plan);
    if (!assumeYes) {
      if (!stdin.hasTerminal) {
        stderr.writeln('Declining: no TTY for consent and --yes not given. '
            'Re-run with --yes to fetch non-interactively.');
        return false;
      }
      stdout.write('Fetch these into the shared corpus? [y/N] ');
      final answer = stdin.readLineSync()?.trim().toLowerCase();
      if (answer != 'y' && answer != 'yes') {
        stdout.writeln('Aborted — nothing downloaded.');
        return false;
      }
    }

    await for (final e in _service.fetchAndIngest(chip, plan)) {
      final progress = e.total > 0 ? ' (${e.done}/${e.total})' : '';
      stderr.writeln('[corpus] ${e.message}$progress');
    }
    final status = _service.statusFor(chip);
    stdout.writeln('Corpus ${chip.corpusKey}: '
        '${status?.chunkCount ?? 0} chunks '
        '(${_kindSummary(status)}).');
    return true;
  }

  void _printPlan(FetchPlan plan) {
    stdout.writeln('Fetch plan for ${plan.corpusKey}:');
    for (final i in plan.items) {
      final size = i.approxBytes != null
          ? ' ~${(i.approxBytes! / (1024 * 1024)).toStringAsFixed(0)} MB'
          : '';
      stdout.writeln('  - ${i.key} [${i.kind.name}]$size'
          '${i.optional ? ' (optional)' : ''}');
      stdout.writeln('      ${i.url}');
      stdout.writeln('      ${i.licenseNote}');
    }
    final totalMb =
        (plan.approxTotalBytes / (1024 * 1024)).toStringAsFixed(0);
    stdout.writeln('  Total: ~$totalMb MB');
    for (final n in plan.notes) {
      stdout.writeln('  note: $n');
    }
  }

  void printStatus(ChipIdentity chip) {
    final status = _service.statusFor(chip);
    if (status == null) {
      stdout.writeln('${chip.corpusKey ?? chip.label}: no corpus fetched.');
      return;
    }
    stdout.writeln('${status.corpusKey}: ${status.chunkCount} chunks '
        '(${_kindSummary(status)})');
    stdout.writeln('  embedding models: ${status.embeddingModels.join(', ')}');
    stdout.writeln('  items: ${status.itemStatuses.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  }

  String _kindSummary(CorpusStatus? status) =>
      (status?.chunkCountsByKind.entries.map((e) => '${e.value} ${e.key}'))
          ?.join(' · ') ??
      '';
}
