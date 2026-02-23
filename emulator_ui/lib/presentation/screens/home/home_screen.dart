import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import '../../../providers/app_providers.dart';
import '../../dialogs/unsaved_changes_dialog.dart';
import '../../widgets/menu_bar_widget.dart';
import '../../widgets/explorer_sidebar.dart';
import '../../widgets/metadata_sidebar.dart';
import '../../widgets/trace_activity_sidebar.dart';
import '../../widgets/graph_viewer_widget.dart';
import '../../widgets/connection_status_indicator.dart';

/// Main screen of the application.
///
/// This implements the VSCode-inspired layout with:
/// - Menu bar at top
/// - Collapsible explorer sidebar on left
/// - Graph viewer in center
/// - Collapsible metadata sidebar on right
/// - Connection status indicator
///
/// Also intercepts the OS window close event to prompt for unsaved changes.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    final emulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);

    if (emulator != null && isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: emulator.name,
      );

      if (action == UnsavedChangesAction.cancel || action == null) {
        return; // Don't close
      }

      if (action == UnsavedChangesAction.save) {
        await _saveBeforeClose(emulator);
      }
    }

    // Kill Python server and clean up services before closing
    try {
      ref.read(emulationOrchestratorProvider).dispose();
    } catch (_) {}

    await windowManager.destroy();
  }

  /// Save emulator before closing. Uses existing path, or defaults to projects dir.
  Future<void> _saveBeforeClose(dynamic emulator) async {
    final repository = ref.read(emulatorRepositoryProvider);
    final savePath = emulator.emulatorPath ??
        p.join(AppPaths.projectsDir, '${emulator.name}${AppConstants.emulatorFileExtension}');

    try {
      final updated = emulator.copyWith(emulatorPath: savePath, modifiedAt: DateTime.now());
      await repository.saveEmulator(updated, savePath);
      ref.read(currentEmulatorProvider.notifier).state = updated;
      ref.read(emulatorDirtyProvider.notifier).state = false;
      await repository.addToRecentEmulators(savePath, emulator.name);
    } catch (e) {
      // If save fails, still allow closing (user chose "Save" — best effort)
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch sidebar expansion states
    final leftExpanded = ref.watch(leftSidebarExpandedProvider);
    final rightExpanded = ref.watch(rightSidebarExpandedProvider);
    final traceExpanded = ref.watch(traceActivitySidebarExpandedProvider);

    // Watch emulator state
    final currentEmulator = ref.watch(currentEmulatorProvider);
    final isDirty = ref.watch(emulatorDirtyProvider);

    // Drive artifact library processing (hash ELF, register firmware/symbols)
    ref.watch(artifactProcessingProvider);

    return Scaffold(
      body: Column(
        children: [
          // Menu bar at the top
          const MenuBarWidget(),

          // Main content area
          Expanded(
            child: Row(
              children: [
                // Left sidebar (Explorer)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: leftExpanded
                      ? AppConstants.sidebarExpandedWidth
                      : AppConstants.sidebarCollapsedWidth,
                  child: const ExplorerSidebar(),
                ),

                // Vertical divider
                const VerticalDivider(width: 1),

                // Center content (Graph Viewer)
                const Expanded(
                  child: GraphViewerWidget(),
                ),

                // Vertical divider
                const VerticalDivider(width: 1),

                // Right sidebar (Metadata)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: rightExpanded
                      ? AppConstants.sidebarExpandedWidth
                      : AppConstants.sidebarCollapsedWidth,
                  child: const MetadataSidebar(),
                ),

                // Vertical divider
                const VerticalDivider(width: 1),

                // Far right sidebar (Trace Activity)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: traceExpanded
                      ? AppConstants.sidebarExpandedWidth
                      : AppConstants.sidebarCollapsedWidth,
                  child: const TraceActivitySidebar(),
                ),
              ],
            ),
          ),

          // Status bar at the bottom
          Container(
            height: AppConstants.statusBarHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).appBarTheme.backgroundColor,
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerTheme.color ?? Colors.grey,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                const ConnectionStatusIndicator(),

                // Emulator info (if emulator is open)
                if (currentEmulator != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 12,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.folder_open, size: 12, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    currentEmulator.name,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  if (isDirty)
                    const Text(
                      ' *',
                      style: TextStyle(fontSize: 11, color: Colors.orange),
                    ),
                ],

                const Spacer(),
                const Text(
                  AppConstants.appVersion,
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
