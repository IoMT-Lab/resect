import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:emulator_orchestrator/data/services/coverage_frontier.dart';
import 'package:test/test.dart';

/// Build a call graph from a simple {caller: [callees]} adjacency map.
CallGraph _graph(Map<String, List<String>> edges) {
  final symbols = <String, Symbol>{
    for (final entry in edges.entries)
      entry.key: Symbol(
        name: entry.key,
        numInstructions: 1,
        calledSymbols: {for (final c in entry.value) c: 1},
      ),
  };
  return CallGraph(elfPath: '/dev/null', symbols: symbols);
}

void main() {
  group('computeFrontier', () {
    test('flags an executed function whose callee never executed', () {
      final graph = _graph({
        'main': ['SystemInit', 'app_main'],
        'SystemInit': ['clock_setup'],
        'app_main': [],
        'clock_setup': [],
      });
      // main + SystemInit executed; clock_setup and app_main did NOT.
      final frontier = computeFrontier(
        executedSymbols: {'main', 'SystemInit'},
        callGraph: graph,
      );
      final symbols = frontier.map((e) => e.symbol).toList();
      // main has an unexecuted callee (app_main); SystemInit has one
      // (clock_setup). Both are on the frontier.
      expect(symbols, containsAll(['main', 'SystemInit']));
    });

    test('ranks by number of unexecuted callees, desc', () {
      final graph = _graph({
        'a': ['x', 'y', 'z'], // 3 unexecuted
        'b': ['w'], //            1 unexecuted
        'x': [],
        'y': [],
        'z': [],
        'w': [],
      });
      final frontier = computeFrontier(
        executedSymbols: {'a', 'b'},
        callGraph: graph,
      );
      expect(frontier.first.symbol, 'a');
      expect(frontier.first.unexecutedCalleeCount, 3);
      expect(frontier[1].symbol, 'b');
      expect(frontier[1].unexecutedCalleeCount, 1);
    });

    test('ties broken by symbol name for determinism', () {
      final graph = _graph({
        'zeta': ['u1'],
        'alpha': ['u2'],
        'u1': [],
        'u2': [],
      });
      final frontier = computeFrontier(
        executedSymbols: {'zeta', 'alpha'},
        callGraph: graph,
      );
      expect(frontier.map((e) => e.symbol).toList(), ['alpha', 'zeta']);
    });

    test('respects topK', () {
      final edges = <String, List<String>>{};
      final executed = <String>{};
      for (var i = 0; i < 20; i++) {
        edges['f$i'] = ['u$i'];
        edges['u$i'] = [];
        executed.add('f$i');
      }
      final frontier = computeFrontier(
        executedSymbols: executed,
        callGraph: _graph(edges),
        topK: 5,
      );
      expect(frontier, hasLength(5));
    });

    test('a fully-explored run yields an empty frontier', () {
      final graph = _graph({
        'main': ['helper'],
        'helper': [],
      });
      final frontier = computeFrontier(
        executedSymbols: {'main', 'helper'},
        callGraph: graph,
      );
      expect(frontier, isEmpty);
    });

    test('empty executed set yields empty frontier', () {
      final graph = _graph({
        'main': ['helper'],
        'helper': [],
      });
      final frontier = computeFrontier(
        executedSymbols: const {},
        callGraph: graph,
      );
      expect(frontier, isEmpty);
    });

    test('executed symbol absent from the graph is skipped, not crashed',
        () {
      final graph = _graph({
        'main': ['helper'],
        'helper': [],
      });
      final frontier = computeFrontier(
        // `ghost` executed but has no graph node.
        executedSymbols: {'main', 'helper', 'ghost'},
        callGraph: graph,
      );
      expect(frontier, isEmpty);
    });

    test('unresolved callee (no graph node) still counts as unexecuted', () {
      final graph = _graph({
        'main': ['plt_stub'], // plt_stub has no node of its own
      });
      final frontier = computeFrontier(
        executedSymbols: {'main'},
        callGraph: graph,
      );
      expect(frontier, hasLength(1));
      expect(frontier.single.unexecutedCallees, ['plt_stub']);
    });
  });
}
