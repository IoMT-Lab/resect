import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_shutdown.dart';
import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/config_providers.dart';
import '../dialogs/system_config_dialog.dart';
import '../dialogs/unsaved_changes_dialog.dart';
import '../screens/callgraph/callgraph_screen.dart';
import '../screens/comms/comms_screen.dart';
import '../screens/library/library_screen.dart';
import '../screens/publish/publish_screen.dart';
import '../screens/synthesize/synthesize_screen.dart';
import '../widgets/menu_bar_widget.dart';
import 'status_bar.dart';
import 'tab_strip.dart';

/// Root Lightroom-inspired tabbed shell.
///
/// Layout:
///   - top strip: identity + tab labels
///   - body: IndexedStack of the five tab screens (so per-tab state survives
///     switching)
///   - bottom: status bar
///
/// Intercepts the window close event to prompt about unsaved changes, the
/// same behavior the original HomeScreen had.
class ResectShell extends ConsumerStatefulWidget {
  const ResectShell({super.key});

  @override
  ConsumerState<ResectShell> createState() => _ResectShellState();
}

class _ResectShellState extends ConsumerState<ResectShell> with WindowListener {
  // Tab screens are kept alive across tab switches via IndexedStack.
  static const _screens = <Widget>[
    LibraryScreen(),
    CallGraphScreen(),
    CommsScreen(),
    SynthesizeScreen(),
    PublishScreen(),
  ];

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // On first launch (no completed setup), show the configuration wizard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(firstRunProvider)) {
        SystemConfigDialog.show(context, wizard: true);
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    // destroy() re-fires GTK's delete-event, which lands here a second
    // time while the window is being torn down — that pass must not
    // re-open the dialog or call destroy() again.
    if (appShutdownInProgress) return;
    final emulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);
    if (emulator != null && isDirty && mounted) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: emulator.name,
      );
      if (action == UnsavedChangesAction.cancel || action == null) {
        return;
      }
      // Save handling will be wired through the Library tab in a follow-up
      // commit; for now both Save and Discard proceed to close.
    }
    await shutdownAndDestroy(ref);
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = ref.watch(activeTabProvider);

    return Scaffold(
      backgroundColor: AppTheme.bgChrome,
      body: Column(
        children: [
          const MenuBarWidget(),
          const TabStrip(),
          const Divider(height: 1, color: AppTheme.border),
          Expanded(
            child: IndexedStack(
              index: activeTab.index,
              children: _screens,
            ),
          ),
          const StatusBar(),
        ],
      ),
    );
  }
}
