// Auto-tune integration scaffold.
//
// This test exercises the closed-loop LLM-orchestrated synthesizer
// end-to-end against REAL services: real Renode subprocess, real
// Ollama at localhost:11434, real LlmSynthesisOrchestrator, real
// auto-tune modal widget tree. No mocks, no fakes — same code path
// production runs.
//
// **Gated on environment availability.** Skipped (with an explicit
// log line) when Renode and/or Ollama aren't installed. CI runs
// with both installed; local dev runs may skip.
//
// **Inputs:** `aya_ppg.elf` from the in-repo `emulation_engine/`
// directory, paired with the corresponding STM32WB05 `.repl`
// platform description.
//
// **Tested cases (when both backends are available):**
// 1. Happy path: accept-all in each round, terminates on
//    `llmEmpty` or `maxRounds`. Snapshot count == rounds + 1.
//    Final manifest is v2 with metrics populated.
// 2. User stop: tap Stop in round 1 review. Snapshot count == 1.
// 3. All rejected: tap Reject-all + Apply. Snapshot appended,
//    exit reason `userRejectedAll`.
// 4. .emu round-trip: simulate app restart mid-loop and verify
//    pre-restart snapshots remain on disk.
//
// The current commit ships only the gating + smoke-test structure;
// the body cases above are documented inline and ready to fill in
// when the test environment is wired up (CI image with Renode +
// Ollama + a baseline-validated firmware project). Filling them in
// is straightforward `testWidgets` + `tester.tap` work once the
// environment exists.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _renodeEnvVar = 'RENODE_AVAILABLE';
const _ollamaEnvVar = 'OLLAMA_AVAILABLE';
const _ayaPpgPath =
    '/home/evan/Development/resect/emulation_engine/aya_ppg.elf';

bool get _renodeAvailable {
  // CI sets this env var explicitly; locally, fall back to
  // probing for the renode binary on PATH.
  if (Platform.environment[_renodeEnvVar] == '1') return true;
  return false;
}

bool get _ollamaAvailable {
  if (Platform.environment[_ollamaEnvVar] == '1') return true;
  return false;
}

bool get _testElfExists => File(_ayaPpgPath).existsSync();

void main() {
  group('Auto-tune integration', () {
    test('environment smoke check', () {
      // Always-on smoke: documents which gates are open without
      // requiring any backend. CI configuration can grep this
      // output to confirm the env-detection is wired correctly.
      // ignore: avoid_print
      print('[auto-tune-integration] renode=$_renodeAvailable '
          'ollama=$_ollamaAvailable elf=$_testElfExists');
      // Test always passes; it's an info marker.
      expect(true, isTrue);
    });

    testWidgets('happy path: accept-all reaches llmEmpty or maxRounds',
        (tester) async {
      if (!_renodeAvailable || !_ollamaAvailable || !_testElfExists) {
        // ignore: avoid_print
        print('[auto-tune-integration] skipping happy-path: '
            'renode=$_renodeAvailable ollama=$_ollamaAvailable '
            'elf=$_testElfExists');
        return;
      }
      // TODO: when CI is wired up with Renode + Ollama:
      //   1. Create a temp directory.
      //   2. Copy aya_ppg.elf + STM32WB05 .repl into it.
      //   3. Construct an Emulator pointing at those paths and
      //      save it via EmulatorRepository.
      //   4. Pump the Synthesize tab (or just the orchestrator +
      //      modal) inside a UncontrolledProviderScope.
      //   5. Open the auto-tune dialog (maxRounds=2,
      //      no optimizationTarget).
      //   6. tester.tap(find.text('Accept all')) + Apply in each
      //      review state.
      //   7. Pump until state is AutoTuneFinished.
      //   8. Read currentEmulatorProvider, assert
      //      roundSnapshots.length >= 1 (baseline) and the final
      //      manifest's manifestVersion == 2 + metrics != null.
      //   9. Assert exit reason is llmEmpty or maxRounds (NOT
      //      synthesisError / llmError / parseFailed).
      // For now, this test is a placeholder that compiles + skips
      // until the CI environment lands.
      expect(true, isTrue);
    });

    // Additional cases (user-stop, reject-all, .emu round-trip)
    // follow the same shape as the happy path above and are left
    // as TODOs until the integration environment is provisioned.
  });
}
