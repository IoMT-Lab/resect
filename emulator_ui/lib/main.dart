import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:emulator_orchestrator/core/app_paths.dart';
import 'core/theme.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import 'presentation/shell/resect_shell.dart';
import 'providers/app_providers.dart';

/// Main entry point for the application.
///
/// This initializes the app, connects to the Python server,
/// and starts the UI.
void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize window manager for close interception
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);

  // Ensure default projects directory exists
  await AppPaths.ensureProjectsDir();

  runApp(
    // ProviderScope enables Riverpod state management throughout the app
    const ProviderScope(
      child: CallGraphViewerApp(),
    ),
  );
}

/// Root application widget.
class CallGraphViewerApp extends ConsumerStatefulWidget {
  const CallGraphViewerApp({super.key});

  @override
  ConsumerState<CallGraphViewerApp> createState() => _CallGraphViewerAppState();
}

class _CallGraphViewerAppState extends ConsumerState<CallGraphViewerApp> {
  @override
  void initState() {
    super.initState();
    // Connect to Python server when app starts
    _connectToServer();
  }

  /// Attempt to connect to the Python backend server.
  Future<void> _connectToServer() async {
    final callgraphService = ref.read(callgraphServiceProvider);
    final lifecycleService = ref.read(lifecycleServiceProvider);

    try {
      // Connect to both services
      final callgraphConnected = await callgraphService.connect();
      final lifecycleConnected = await lifecycleService.connect();

      if (callgraphConnected && lifecycleConnected) {
        print('✓ Successfully connected to server (callgraph + lifecycle)');
      } else {
        print('✗ Failed to connect to server');
      }
    } catch (e) {
      print('✗ Error connecting to server: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      theme: AppTheme.darkTheme,
      home: const ResectShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}
