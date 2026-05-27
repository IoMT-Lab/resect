import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import 'env_config.dart';

/// The kind of value a [ConfigVariable] holds — drives the inline validator.
enum ConfigVarType { directory, file, executable, port, string }

/// Where a variable surfaces in the configuration UI.
enum ConfigTier {
  /// Auto-detected runtime value; shown up-front, editable as an override.
  detected,

  /// Rarely changed; tucked under an "Advanced" disclosure.
  advanced,

  /// Consumed only by install.sh / run.sh — not by the running app. Shown under
  /// a "Build & tooling" disclosure and labeled as not affecting this session.
  build,
}

/// One editable entry in the System Configuration "CMake-GUI" table.
class ConfigVariable {
  const ConfigVariable({
    required this.key,
    required this.label,
    required this.description,
    required this.type,
    required this.tier,
    this.optional = false,
  });

  final String key;
  final String label;
  final String description;
  final ConfigVarType type;
  final ConfigTier tier;

  /// When true, a blank value is valid (the system falls back to a default).
  final bool optional;
}

/// Result of validating a single config value.
class ConfigValidation {
  const ConfigValidation(this.ok, this.message);
  final bool ok;
  final String message;
}

/// The v1 build/environment variables surfaced in the configuration UI. These
/// mirror what `install.sh` / `run.sh` previously hardcoded.
const configVariables = <ConfigVariable>[
  // --- Detected (runtime) ---------------------------------------------------
  ConfigVariable(
    key: 'ENGINE_DIR',
    label: 'Engine directory',
    description: 'The emulation_engine directory (holds the Renode binary).',
    type: ConfigVarType.directory,
    tier: ConfigTier.detected,
  ),
  ConfigVariable(
    key: 'ARM_OBJDUMP',
    label: 'ARM objdump',
    description: 'arm-none-eabi-objdump used for ARM call-graph extraction.',
    type: ConfigVarType.executable,
    tier: ConfigTier.detected,
  ),
  ConfigVariable(
    key: 'X86_OBJDUMP',
    label: 'x86 objdump',
    description: 'objdump used for x86 call-graph extraction.',
    type: ConfigVarType.executable,
    tier: ConfigTier.detected,
  ),
  // --- Advanced (rarely changed) --------------------------------------------
  ConfigVariable(
    key: 'RENODE_BIN',
    label: 'Renode binary (override)',
    description: 'Explicit Renode executable. Blank = derived from the engine '
        'directory and portable folder below.',
    type: ConfigVarType.file,
    tier: ConfigTier.advanced,
    optional: true,
  ),
  ConfigVariable(
    key: 'RENODE_PORTABLE',
    label: 'Renode portable folder',
    description: 'Folder name of the portable Renode build under the engine dir.',
    type: ConfigVarType.string,
    tier: ConfigTier.advanced,
  ),
  ConfigVariable(
    key: 'RENODE_PORT',
    label: 'Renode port',
    description: 'Server-mode port Renode listens on.',
    type: ConfigVarType.port,
    tier: ConfigTier.advanced,
  ),
  ConfigVariable(
    key: 'RENODE_LOG_PATH',
    label: 'Renode log directory',
    description: 'Where Renode stdout/stderr is written.',
    type: ConfigVarType.directory,
    tier: ConfigTier.advanced,
  ),
  // --- Build & tooling (scripts only, not this session) ---------------------
  ConfigVariable(
    key: 'FLUTTER_DIR',
    label: 'Flutter SDK',
    description: 'Directory containing bin/flutter. Used by install.sh / run.sh '
        'to build and launch the app — changing it affects the next launch, '
        'not the running session.',
    type: ConfigVarType.directory,
    tier: ConfigTier.build,
  ),
];

/// Compute a sensible default for [v], using already-set values in [cfg] for
/// interdependent keys (e.g. RENODE_BIN depends on ENGINE_DIR). Returns '' when
/// nothing can be detected.
String detectDefault(ConfigVariable v, EnvConfig cfg) {
  switch (v.key) {
    case 'FLUTTER_DIR':
      return _detectFlutterDir();
    case 'ENGINE_DIR':
      try {
        return AppPaths.findEngineDir();
      } catch (_) {
        final root = AppPaths.findRepoRoot();
        return root != null ? p.join(root, 'emulation_engine') : '';
      }
    case 'RENODE_PORTABLE':
      return 'renode_1.16.0-dotnet_portable';
    case 'RENODE_BIN':
      final engineDir = cfg.get('ENGINE_DIR') ?? detectDefault(_byKey('ENGINE_DIR'), cfg);
      final portable = cfg.get('RENODE_PORTABLE') ?? 'renode_1.16.0-dotnet_portable';
      return engineDir.isEmpty ? '' : p.join(engineDir, portable, 'renode');
    case 'RENODE_PORT':
      return '5000';
    case 'RENODE_LOG_PATH':
      return '/tmp/renode_logs';
    case 'ARM_OBJDUMP':
      return which('arm-none-eabi-objdump') ?? 'arm-none-eabi-objdump';
    case 'X86_OBJDUMP':
      return which('objdump') ?? 'objdump';
    default:
      return '';
  }
}

/// Validate [value] for variable [v]; surfaced inline as red/green status.
ConfigValidation validateConfigValue(ConfigVariable v, String value) {
  final val = value.trim();
  if (val.isEmpty) {
    return v.optional
        ? const ConfigValidation(true, 'optional — using default')
        : const ConfigValidation(false, 'required');
  }
  switch (v.type) {
    case ConfigVarType.directory:
      if (!Directory(val).existsSync()) {
        return const ConfigValidation(false, 'directory not found');
      }
      if (v.key == 'FLUTTER_DIR' &&
          !File(p.join(val, 'bin', 'flutter')).existsSync()) {
        return const ConfigValidation(false, 'no bin/flutter here');
      }
      if ((v.key == 'RENODE_DART_PATH' || v.key == 'CALLGRAPH_DART_PATH') &&
          !File(p.join(val, 'pubspec.yaml')).existsSync()) {
        return const ConfigValidation(false, 'no pubspec.yaml here');
      }
      return const ConfigValidation(true, 'ok');
    case ConfigVarType.file:
      return File(val).existsSync()
          ? const ConfigValidation(true, 'ok')
          : const ConfigValidation(false, 'file not found');
    case ConfigVarType.executable:
      final resolved = which(val);
      return resolved != null
          ? ConfigValidation(true, resolved)
          : const ConfigValidation(false, 'not found on PATH');
    case ConfigVarType.port:
      final n = int.tryParse(val);
      if (n == null || n < 1 || n > 65535) {
        return const ConfigValidation(false, 'invalid port (1–65535)');
      }
      return const ConfigValidation(true, 'ok');
    case ConfigVarType.string:
      return const ConfigValidation(true, 'ok');
  }
}

ConfigVariable _byKey(String key) =>
    configVariables.firstWhere((v) => v.key == key);

/// Resolve a command via PATH (or verify an absolute path), like `which`.
String? which(String cmd) {
  if (cmd.contains('/')) return File(cmd).existsSync() ? cmd : null;
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.isEmpty) continue;
    final f = File(p.join(dir, cmd));
    if (f.existsSync()) return f.path;
  }
  return null;
}

String _detectFlutterDir() {
  final onPath = which('flutter');
  if (onPath != null) {
    // <dir>/bin/flutter → <dir>
    return Directory(p.dirname(onPath)).parent.path;
  }
  final home = Platform.environment['HOME'] ?? '';
  for (final candidate in [
    p.join(home, 'Development', 'flutter'),
    p.join(home, 'development', 'flutter'),
  ]) {
    if (File(p.join(candidate, 'bin', 'flutter')).existsSync()) return candidate;
  }
  return '';
}

