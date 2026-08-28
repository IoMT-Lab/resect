import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import '../providers/app_providers.dart';
import '../providers/comms_bus_provider.dart';
import '../providers/config_providers.dart';

/// Whether an app shutdown is already in progress.
///
/// `windowManager.destroy()` re-fires GTK's `delete-event`, which the
/// window_manager plugin re-emits as a second `"close"` event on the
/// Dart side — WHILE the window is being torn down. Without this guard
/// that second pass re-runs the close handler (unsaved-changes dialog
/// and all) and calls `destroy()` again against a dying GtkWindow.
/// Both exit paths must check-and-set it before doing anything else.
var _shuttingDown = false;

/// True once [shutdownAndDestroy] has started; callers use this to make
/// re-entrant close events no-ops.
bool get appShutdownInProgress => _shuttingDown;

/// Reset the guard — tests only.
void resetAppShutdownForTest() => _shuttingDown = false;

/// The final window-close call — replaceable so tests can observe it
/// (the window_manager platform channel doesn't exist under
/// flutter_test).
///
/// Lift the prevent-close guard and CLOSE rather than destroy():
/// destroy() force-tears the window while the plugin's re-fired "close"
/// notification is still in flight, so it lands on a messenger whose
/// engine is already gone ("Attempted to set message handler on an
/// FlBinaryMessenger without an engine" on stderr). A normal close lets
/// that event deliver while the engine is alive — the shutdown guard
/// makes it a no-op — and GTK then winds the window down in order.
@visibleForTesting
Future<void> Function() destroyWindow = () async {
  await windowManager.setPreventClose(false);
  await windowManager.close();
};

/// Tear down the app's native/threaded resources, then destroy the
/// window. Idempotent: the second and later calls return immediately.
///
/// Nothing else disposes these: every teardown hook in the app is a
/// Riverpod `ref.onDispose`, and no exit path ever unmounts the
/// ProviderScope — the GTK window dies with the drift background
/// isolate, sqlite handles, WebSocket client, and UDP sockets still
/// live, which is how the process ends in a SIGSEGV (exit 139) instead
/// of a clean 0. Each step is best-effort and the whole sequence is
/// time-bounded so a wedged resource can never prevent exit.
Future<void> shutdownAndDestroy(WidgetRef ref) async {
  if (_shuttingDown) return;
  _shuttingDown = true;

  await _teardown(ref).timeout(const Duration(seconds: 3), onTimeout: () {
    stderr.writeln('[shutdown] teardown timed out — exiting anyway');
  });
  await destroyWindow();
}

Future<void> _teardown(WidgetRef ref) async {
  Future<void> step(String name, FutureOr<void> Function() run) async {
    try {
      await run();
    } catch (e) {
      stderr.writeln('[shutdown] $name failed: $e');
    }
  }

  // A live auto-tune session first — stop it asking the LLM/engine for
  // more work while everything below closes underneath it.
  await step('auto-tune cancel', () {
    ref.read(autoTuneOrchestratorProvider)?.cancel();
  });
  // UDP comms servers.
  await step('comms bus', () => ref.read(commsBusServiceProvider).dispose());
  // Engine + Renode WebSocket client + workflow stream controllers.
  // Closing the orchestrator's event controller also ends the
  // fire-and-forget events subscription wired up at provider build.
  await step('orchestrator', () => ref.read(emulationOrchestratorProvider).dispose());
  // The drift background isolate holding the sqlite FFI handle — the
  // prime teardown-crash suspect. close() joins the isolate.
  await step('artifact db', () => ref.read(artifactDatabaseProvider).close());
  // RAG sqlite (main-isolate FFI handle, WAL journal).
  await step('rag index', () => ref.read(ragIndexProvider)?.close());
  // Locally-spawned `ollama serve` (native installs only; docker no-op).
  await step('ollama daemon', () => ref.read(ollamaInstallerProvider).stopDaemon());
  // Ollama HTTP client.
  await step('llm client', () => ref.read(llmClientProvider).close());
}
