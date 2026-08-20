import 'dart:io';

import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_guard.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:emulator_ui/providers/autosave_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the wrong-firmware call-graph incident: an
/// auto-tune session emulated aya_ppg.elf while the LLM layer reasoned
/// over the dispensing-cabinet demo's cached graph. Two seams are
/// under test:
///
/// 1. `gatherState` (save path) must never persist a graph that belongs
///    to a different firmware than the ELF the save records — the stale
///    `callgraphProvider.valueOrNull` served during re-extraction is
///    exactly how the .emu got poisoned.
/// 2. `resolveSessionCallGraph` (auto-tune start) must reject a cached
///    graph whose sha256 stamp doesn't match the session ELF and adopt
///    a validated one, writing it back onto the project.
void main() {
  late Directory tmp;
  late String elfPath;

  CallGraph graph({required String elfPath, String? elfHash}) => CallGraph(
        elfPath: elfPath,
        elfHash: elfHash,
        symbols: {
          'main': Symbol(
              name: 'main', numInstructions: 4, calledSymbols: const {}),
        },
      );

  Emulator project({String? elf, CallGraph? cached}) =>
      Emulator.create(name: 'p', elfFilePath: elf)
          .copyWith(cachedCallGraph: cached);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cg_trust_test');
    elfPath = '${tmp.path}/fw.elf';
    await File(elfPath).writeAsBytes([7, 7, 7, 7]);
  });

  tearDown(() => tmp.delete(recursive: true));

  group('gatherState call-graph persistence', () {
    Future<Emulator> gather({
      required Emulator base,
      required String selectedElf,
      CallGraph? liveGraph,
    }) async {
      final container = ProviderContainer(overrides: [
        selectedElfPathProvider.overrideWith((ref) => selectedElf),
        callgraphProvider.overrideWith((ref) => Future.value(liveGraph)),
      ]);
      addTearDown(container.dispose);
      // Settle the FutureProvider so valueOrNull serves the graph, the
      // way a loaded session does.
      await container.read(callgraphProvider.future);
      return container.read(autosaveControllerProvider).gatherState(base);
    }

    test('persists the live graph when it belongs to the saved ELF',
        () async {
      final live = graph(elfPath: elfPath, elfHash: 'a' * 64);
      final saved = await gather(
        base: project(elf: elfPath),
        selectedElf: elfPath,
        liveGraph: live,
      );
      expect(saved.cachedCallGraph, same(live));
    });

    test('never persists a live graph from a different firmware (the '
        'poisoned-save shape)', () async {
      // The provider still serves the PREVIOUS project's graph while
      // re-extraction runs — that graph must not land in this save.
      final stale = graph(elfPath: '/other/cabinet.elf', elfHash: 'b' * 64);
      final saved = await gather(
        base: project(elf: elfPath),
        selectedElf: elfPath,
        liveGraph: stale,
      );
      expect(saved.cachedCallGraph, isNull);
    });

    test('keeps the base graph when the live one is stale', () async {
      final own = graph(elfPath: elfPath, elfHash: 'c' * 64);
      final stale = graph(elfPath: '/other/cabinet.elf', elfHash: 'b' * 64);
      final saved = await gather(
        base: project(elf: elfPath, cached: own),
        selectedElf: elfPath,
        liveGraph: stale,
      );
      expect(saved.cachedCallGraph, same(own));
    });

    test('drops a mismatched base graph — a save cleans a poisoned .emu',
        () async {
      final poison = graph(elfPath: '/other/cabinet.elf', elfHash: 'b' * 64);
      final saved = await gather(
        base: project(elf: elfPath, cached: poison),
        selectedElf: elfPath,
        liveGraph: null,
      );
      expect(saved.cachedCallGraph, isNull);
    });
  });

  group('resolveSessionCallGraph', () {
    test('uses a cached graph whose stamp matches the session ELF',
        () async {
      final valid =
          graph(elfPath: elfPath, elfHash: await sha256OfFile(elfPath));
      final container = ProviderContainer(overrides: [
        callgraphProvider.overrideWith((ref) => Future.value(null)),
      ]);
      addTearDown(container.dispose);
      container.read(currentEmulatorProvider.notifier).state =
          project(elf: elfPath, cached: valid);

      final resolved = await resolveSessionCallGraph(container);
      expect(resolved, same(valid));
    });

    test('rejects a poisoned cached graph and adopts the validated live '
        'one, writing it back onto the project (the incident)', () async {
      // Cached graph stamped for OTHER firmware bytes — the cabinet
      // graph inside the aya project.
      final poison =
          graph(elfPath: '/other/cabinet.elf', elfHash: 'd' * 64);
      final valid =
          graph(elfPath: elfPath, elfHash: await sha256OfFile(elfPath));
      final container = ProviderContainer(overrides: [
        callgraphProvider.overrideWith((ref) => Future.value(valid)),
      ]);
      addTearDown(container.dispose);
      container.read(currentEmulatorProvider.notifier).state =
          project(elf: elfPath, cached: poison);
      await container.read(callgraphProvider.future);

      final resolved = await resolveSessionCallGraph(container);
      expect(resolved, same(valid));
      expect(
        container.read(currentEmulatorProvider)!.cachedCallGraph,
        same(valid),
        reason: 'the validated graph must replace the poison on the '
            'project so the next save persists it',
      );
    });

    test('throws when the project has no firmware ELF', () async {
      final container = ProviderContainer(overrides: [
        callgraphProvider.overrideWith((ref) => Future.value(null)),
      ]);
      addTearDown(container.dispose);
      container.read(currentEmulatorProvider.notifier).state = project();
      expect(resolveSessionCallGraph(container), throwsStateError);
    });
  });
}
