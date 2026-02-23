import 'dart:io';
import 'package:path/path.dart' as p;

/// Centralized application path constants.
///
/// All app-specific directories live under `~/.config/call_graph_viewer/`.
class AppPaths {
  static String get configDir {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, '.config', 'call_graph_viewer');
  }

  /// Default directory for saved `.emu` emulator projects.
  static String get projectsDir => p.join(configDir, 'projects');

  /// Directory for the artifact library SQLite database.
  static String get artifactDbDir => p.join(configDir, 'artifact_library');

  /// Directory for document files associated with a specific emulator.
  static String documentsDir(String emulatorId) =>
      p.join(projectsDir, emulatorId, 'documents');

  /// Ensure the projects directory exists, return its path.
  static Future<String> ensureProjectsDir() async {
    final dir = Directory(projectsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return projectsDir;
  }
}
