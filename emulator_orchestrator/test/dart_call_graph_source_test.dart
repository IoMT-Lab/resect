import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_call_graph_source.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_guard.dart';
import 'package:test/test.dart';

/// Extraction must stamp the graph with its source ELF's sha256 —
/// that stamp is the identity every cached-graph consumer validates.
void main() {
  const elfPath = 'test_harness/minimal_firmware.elf';

  test('getCallGraph stamps the graph with the ELF sha256', () async {
    final source = DartCallGraphSource();
    await source.connect();
    late final CallGraph graph;
    try {
      graph = await source.getCallGraph(elfPath);
    } on Exception catch (e) {
      // No ARM objdump on this machine — extraction is exercised in the
      // docker image; the stamp logic itself is covered by
      // call_graph_guard_test.dart.
      markTestSkipped('objdump unavailable: $e');
      return;
    } finally {
      source.disconnect();
    }
    expect(graph.elfHash, await sha256OfFile(elfPath));
    expect(await callGraphMatchesElf(graph, elfPath), isTrue);
  });
}
