import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:test/test.dart';

/// failureLabel: the reason-aware failure string. Cap/cancel endings
/// deliberately carry no failed symbol — the label must say what
/// happened and must NEVER render the string "null".
void main() {
  SynthesizerResult result({
    String? failedSymbol,
    SynthesisTerminationReason? reason,
    int iterations = 500,
  }) =>
      SynthesizerResult(
        success: false,
        totalIterations: iterations,
        resolvedHooks: const {},
        resolvedHookCode: const {},
        failedSymbol: failedSymbol,
        terminationReason: reason,
        totalDuration: const Duration(seconds: 1),
      );

  test('iteration cap names the cap, not a symbol', () {
    final label = result(
      reason: SynthesisTerminationReason.maxIterations,
      iterations: 500,
    ).failureLabel;
    expect(label, 'Stopped — iteration cap reached (500 iterations)');
    expect(label.contains('null'), isFalse);
  });

  test('cancellation says Cancelled', () {
    expect(result(reason: SynthesisTerminationReason.cancelled).failureLabel,
        'Cancelled');
  });

  test('symbol faults keep the Failed-at wording', () {
    expect(
        result(
          failedSymbol: 'SystemInit',
          reason: SynthesisTerminationReason.symbolExhausted,
        ).failureLabel,
        'Failed at SystemInit');
    expect(
        result(
          failedSymbol: 'HAL_Init',
          reason: SynthesisTerminationReason.forcedOverrideFailed,
        ).failureLabel,
        'Failed at HAL_Init');
  });

  test('legacy result with no reason and no symbol never says null', () {
    final label = result().failureLabel;
    expect(label, 'Failed');
    expect(label.contains('null'), isFalse);
  });
}
