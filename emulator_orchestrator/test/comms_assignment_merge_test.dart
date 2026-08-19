import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as m;
import 'package:emulator_orchestrator/services/comms/comms_assignment_merge.dart';
import 'package:test/test.dart';

CallGraph _graphOf(Iterable<String> names) => CallGraph(
      elfPath: '/dev/null',
      symbols: {
        for (final n in names)
          n: m.Symbol(name: n, numInstructions: 1, calledSymbols: const {}),
      },
    );

const _i2cRead = CommsAssignment(protocol: CommsClass.i2c, role: CommsRole.read);
const _i2cWrite = CommsAssignment(protocol: CommsClass.i2c, role: CommsRole.write);
const _uartWrite = CommsAssignment(protocol: CommsClass.uart, role: CommsRole.write);
const _dismissed = CommsAssignment(protocol: CommsClass.unclassified);

void main() {
  group('mergeCommsAssignments', () {
    test('existing entry wins over a differing suggestion', () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a']),
        existing: {'a': _uartWrite},
        suggestions: {'a': _i2cRead},
      );
      expect(merged['a'], _uartWrite);
    });

    test('new symbol gets the suggestion', () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a', 'b']),
        existing: {'a': _i2cRead},
        suggestions: {'b': _uartWrite},
      );
      expect(merged, {'a': _i2cRead, 'b': _uartWrite});
    });

    test('symbol dropped from the graph is pruned', () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a']),
        existing: {'a': _i2cRead, 'gone': _uartWrite},
        suggestions: const {},
      );
      expect(merged, {'a': _i2cRead});
    });

    test('unclassified dismissal beats a protocol suggestion', () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a']),
        existing: {'a': _dismissed},
        suggestions: {'a': _i2cRead},
      );
      expect(merged['a'], _dismissed);
    });

    test('symbol in neither map stays absent', () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a', 'plain']),
        existing: const {},
        suggestions: {'a': _i2cRead},
      );
      expect(merged.containsKey('plain'), isFalse);
    });

    test('empty existing degenerates to the suggestions for present symbols',
        () {
      final merged = mergeCommsAssignments(
        graph: _graphOf(['a', 'b']),
        existing: const {},
        suggestions: {'a': _i2cRead, 'b': _i2cWrite, 'notInGraph': _uartWrite},
      );
      expect(merged, {'a': _i2cRead, 'b': _i2cWrite});
    });

    test('idempotent: re-merging the merged output changes nothing', () {
      final graph = _graphOf(['a', 'b', 'c']);
      final suggestions = {'a': _i2cRead, 'c': _uartWrite};
      final once = mergeCommsAssignments(
        graph: graph,
        existing: {'b': _dismissed},
        suggestions: suggestions,
      );
      final twice = mergeCommsAssignments(
        graph: graph,
        existing: once,
        suggestions: suggestions,
      );
      expect(commsAssignmentsEqual(once, twice), isTrue);
    });
  });

  group('commsAssignmentsEqual', () {
    test('equal maps compare equal', () {
      expect(
        commsAssignmentsEqual(
          {'a': _i2cRead, 'b': _uartWrite},
          {'a': _i2cRead, 'b': _uartWrite},
        ),
        isTrue,
      );
    });

    test('role difference detected', () {
      expect(
        commsAssignmentsEqual({'a': _i2cRead}, {'a': _i2cWrite}),
        isFalse,
      );
    });

    test('size difference detected', () {
      expect(
        commsAssignmentsEqual({'a': _i2cRead}, {'a': _i2cRead, 'b': _uartWrite}),
        isFalse,
      );
    });
  });
}
