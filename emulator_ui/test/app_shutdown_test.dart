import 'package:emulator_ui/core/app_shutdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guarded shutdown path: window_manager's destroy() re-fires the
/// close event during GTK teardown, so the shutdown must be idempotent —
/// the resources are torn down once and the window destroyed once, no
/// matter how many times the close handler re-enters.
void main() {
  testWidgets('shutdownAndDestroy tears down once and destroys once',
      (tester) async {
    resetAppShutdownForTest();
    var destroys = 0;
    destroyWindow = () async => destroys++;

    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) {
          capturedRef = ref;
          return const SizedBox.shrink();
        }),
      ),
    ));

    expect(appShutdownInProgress, isFalse);
    final first = shutdownAndDestroy(capturedRef);
    // Re-entrant pass (the second "close" event) must be a no-op.
    expect(appShutdownInProgress, isTrue);
    final second = shutdownAndDestroy(capturedRef);
    await tester.runAsync(() => Future.wait([first, second]));

    expect(destroys, 1);
    expect(appShutdownInProgress, isTrue);
    resetAppShutdownForTest();
  });
}
