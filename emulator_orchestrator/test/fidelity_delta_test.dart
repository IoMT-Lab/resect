import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/analysis/fidelity_delta.dart';
import 'package:test/test.dart';

ManifestMetrics metrics({
  required double overall,
  double? coverage,
  double? subgraph,
  int intact = 0,
  int degraded = 0,
  int hooked = 0,
}) =>
    ManifestMetrics(
      overallFidelity: overall,
      coverageFidelity: coverage,
      subgraphFidelity: subgraph,
      intactCount: intact,
      degradedCount: degraded,
      hookedCount: hooked,
    );

void main() {
  group('FidelityDelta.compute', () {
    test('identical metrics produce a flat delta', () {
      final m = metrics(overall: 0.7, coverage: 0.8, subgraph: 0.9);
      final d = FidelityDelta.compute(
        prior: m,
        current: m,
        priorExecutedCount: 50,
        currentExecutedCount: 50,
      );
      expect(d.overallFidelityDelta, 0);
      expect(d.coverageFidelityDelta, 0);
      expect(d.subgraphFidelityDelta, 0);
      expect(d.executedSymbolsDelta, 0);
      expect(d.isFlat, isTrue);
    });

    test('improvement on every metric', () {
      final prior = metrics(overall: 0.5, coverage: 0.6, subgraph: 0.7);
      final current = metrics(overall: 0.8, coverage: 0.85, subgraph: 0.9);
      final d = FidelityDelta.compute(
        prior: prior,
        current: current,
        priorExecutedCount: 40,
        currentExecutedCount: 55,
      );
      expect(d.overallFidelityDelta, closeTo(0.3, 1e-9));
      expect(d.coverageFidelityDelta, closeTo(0.25, 1e-9));
      expect(d.subgraphFidelityDelta, closeTo(0.2, 1e-9));
      expect(d.executedSymbolsDelta, 15);
      expect(d.isFlat, isFalse);
    });

    test('regression on every metric produces negative deltas', () {
      final prior = metrics(overall: 0.8, coverage: 0.85, subgraph: 0.9);
      final current = metrics(overall: 0.5, coverage: 0.6, subgraph: 0.7);
      final d = FidelityDelta.compute(
        prior: prior,
        current: current,
        priorExecutedCount: 55,
        currentExecutedCount: 40,
      );
      expect(d.overallFidelityDelta, closeTo(-0.3, 1e-9));
      expect(d.coverageFidelityDelta, lessThan(0));
      expect(d.subgraphFidelityDelta, lessThan(0));
      expect(d.executedSymbolsDelta, -15);
    });

    test('coverage delta is null when either side lacks coverage', () {
      final prior = metrics(overall: 0.5);
      final current = metrics(overall: 0.6, coverage: 0.7);
      final d = FidelityDelta.compute(prior: prior, current: current);
      expect(d.overallFidelityDelta, closeTo(0.1, 1e-9));
      expect(d.coverageFidelityDelta, isNull);
    });

    test('subgraph delta is null when either side lacks subgraph', () {
      final prior = metrics(overall: 0.5, subgraph: 0.6);
      final current = metrics(overall: 0.6);
      final d = FidelityDelta.compute(prior: prior, current: current);
      expect(d.subgraphFidelityDelta, isNull);
    });

    test('mixed directions: coverage up, overall flat', () {
      final prior = metrics(overall: 0.5, coverage: 0.4);
      final current = metrics(overall: 0.5, coverage: 0.7);
      final d = FidelityDelta.compute(prior: prior, current: current);
      expect(d.overallFidelityDelta, 0);
      expect(d.coverageFidelityDelta, closeTo(0.3, 1e-9));
      expect(d.isFlat, isFalse);
    });

    test('toJson omits null delta fields', () {
      final d = FidelityDelta.compute(
        prior: metrics(overall: 0.5),
        current: metrics(overall: 0.6),
      );
      final json = d.toJson();
      expect(json.containsKey('coverage_fidelity_delta'), isFalse);
      expect(json.containsKey('subgraph_fidelity_delta'), isFalse);
      expect(json['overall_fidelity_delta'], closeTo(0.1, 1e-9));
      expect(json['executed_symbols_delta'], 0);
    });
  });
}
