import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/theme.dart';
import 'presentation/shell/resect_shell.dart';

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
class CallGraphViewerApp extends ConsumerWidget {
  const CallGraphViewerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
      title: AppConstants.appName,
      theme: AppTheme.darkTheme,
      home: const ResectShell(),
      debugShowCheckedModeBanner: false,
    );
}
