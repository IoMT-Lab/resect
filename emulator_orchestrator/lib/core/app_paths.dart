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

  /// Find the emulation_engine directory relative to the current working directory.
  ///
  /// Checks two locations in order:
  /// 1. `./emulation_engine`   (cwd is the workspace root)
  /// 2. `../emulation_engine`  (cwd is a package subdir like emulator_ui/)
  static String findEngineDir() {
    final candidates = [
      '${Directory.current.path}/emulation_engine',
      '${Directory.current.parent.path}/emulation_engine',
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    throw StateError(
      'Could not find emulation_engine directory. '
      'Searched: ${candidates.join(', ')}',
    );
  }

  /// Walk up from the current working directory to find the repo root —
  /// identified by the presence of `install.sh`. Returns null if not found
  /// (e.g. an installed app launched outside the source tree).
  static String? findRepoRoot() {
    var dir = Directory.current;
    for (var i = 0; i < 8; i++) {
      if (File(p.join(dir.path, 'install.sh')).existsSync()) {
        return dir.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// Ensure the projects directory exists, return its path.
  static Future<String> ensureProjectsDir() async {
    final dir = Directory(projectsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return projectsDir;
  }
}
