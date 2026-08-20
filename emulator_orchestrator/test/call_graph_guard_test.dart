import 'dart:io';

import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_guard.dart';
import 'package:test/test.dart';

/// The call-graph identity guard: a cached graph is trusted ONLY when
/// its sha256 stamp matches the ELF's current bytes. This is the fix for
/// the observed incident where an auto-tune session emulated one
/// firmware while the LLM layer reasoned over another firmware's cached
/// graph.
void main() {
  late Directory tmp;
  late String elfPath;

  CallGraph graph({String? elfHash, String elfPath = '/some/fw.elf'}) =>
      CallGraph(
        elfPath: elfPath,
        elfHash: elfHash,
        symbols: {
          'main': Symbol(
              name: 'main', numInstructions: 4, calledSymbols: const {}),
        },
      );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cg_guard_test');
    elfPath = '${tmp.path}/fw.elf';
    await File(elfPath).writeAsBytes([1, 2, 3, 4]);
  });

  tearDown(() => tmp.delete(recursive: true));

  group('sha256OfFile', () {
    test('digests file bytes as sha256 hex', () async {
      // sha256 of [1,2,3,4], independently computed.
      expect(
          await sha256OfFile(elfPath),
          '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a');
    });

    test('throws FileSystemException for a missing file', () {
      expect(() => sha256OfFile('${tmp.path}/nope.elf'),
          throwsA(isA<FileSystemException>()));
    });
  });

  group('callGraphMatchesElf', () {
    test('matches when the stamp equals the file digest', () async {
      final stamped = graph(elfHash: await sha256OfFile(elfPath));
      expect(await callGraphMatchesElf(stamped, elfPath), isTrue);
    });

    test('rejects a stamp from different bytes', () async {
      final stamped = graph(elfHash: 'a' * 64);
      expect(await callGraphMatchesElf(stamped, elfPath), isFalse);
    });

    test('rejects an unstamped (legacy) graph even when paths agree',
        () async {
      final legacy = graph(elfPath: elfPath);
      expect(await callGraphMatchesElf(legacy, elfPath), isFalse);
    });

    test('rejects after the file at the same path is replaced', () async {
      final stamped =
          graph(elfHash: await sha256OfFile(elfPath), elfPath: elfPath);
      await File(elfPath).writeAsBytes([9, 9, 9]);
      expect(await callGraphMatchesElf(stamped, elfPath), isFalse);
    });
  });

  group('ensureCallGraphForElf', () {
    test('returns a valid cached graph without generating', () async {
      final cached = graph(elfHash: await sha256OfFile(elfPath));
      var generated = 0;
      final resolved = await ensureCallGraphForElf(
        elfPath: elfPath,
        cached: cached,
        generate: (_) async {
          generated++;
          return graph();
        },
      );
      expect(identical(resolved, cached), isTrue);
      expect(generated, 0);
    });

    test('falls through mismatched cached to a valid fallback', () async {
      final fallback = graph(elfHash: await sha256OfFile(elfPath));
      var generated = 0;
      final resolved = await ensureCallGraphForElf(
        elfPath: elfPath,
        cached: graph(elfHash: 'b' * 64),
        fallback: fallback,
        generate: (_) async {
          generated++;
          return graph();
        },
      );
      expect(identical(resolved, fallback), isTrue);
      expect(generated, 0);
    });

    test('regenerates when every candidate mismatches (the incident shape)',
        () async {
      // Cached graph stamped for OTHER firmware bytes — exactly the
      // poisoned-.emu case: it must never be handed to the LLM layer.
      final fresh = graph(elfHash: await sha256OfFile(elfPath));
      final resolved = await ensureCallGraphForElf(
        elfPath: elfPath,
        cached: graph(elfHash: 'c' * 64),
        fallback: graph(), // unstamped legacy
        generate: (path) async {
          expect(path, elfPath);
          return fresh;
        },
      );
      expect(identical(resolved, fresh), isTrue);
    });

    test('regenerates when no candidates exist', () async {
      final fresh = graph();
      final resolved = await ensureCallGraphForElf(
        elfPath: elfPath,
        generate: (_) async => fresh,
      );
      expect(identical(resolved, fresh), isTrue);
    });

    test('surfaces a missing ELF as a FileSystemException', () {
      expect(
        () => ensureCallGraphForElf(
          elfPath: '${tmp.path}/gone.elf',
          generate: (_) async => graph(),
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('CallGraph elfHash serialization', () {
    test('round-trips through toJson/fromSerializedJson', () {
      final g = graph(elfHash: 'd' * 64);
      final back = CallGraph.fromSerializedJson(g.toJson());
      expect(back.elfHash, 'd' * 64);
      expect(back.elfPath, g.elfPath);
      expect(back.symbols.keys, g.symbols.keys);
    });

    test('legacy JSON without elfHash loads with null (must-regenerate)', () {
      final json = graph().toJson()..remove('elfHash');
      final back = CallGraph.fromSerializedJson(json);
      expect(back.elfHash, isNull);
    });
  });
}
