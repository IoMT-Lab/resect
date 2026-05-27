import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';

/// Reads and writes the repo-local `resect.config` key=value file — the single
/// source of truth shared by the Flutter app and the bash scripts
/// (`install.sh` / `run.sh`, which `source` it).
///
/// Format is plain `KEY="value"` lines (bash-sourceable) with `#` comments.
/// The app reads typed values via [get]/[getBool]; the System Configuration UI
/// mutates and [save]s it.
class EnvConfig {
  EnvConfig(this.path, this._values);

  /// Absolute path to the backing `resect.config` file.
  final String path;
  final Map<String, String> _values;

  /// Resolve where `resect.config` lives:
  ///   1. `$RESECT_CONFIG` env override
  ///   2. `<repoRoot>/resect.config` (canonical — shared with the scripts)
  ///   3. `<configDir>/resect.config` (fallback for installed app)
  static String resolveConfigPath() {
    final override = Platform.environment['RESECT_CONFIG'];
    if (override != null && override.isNotEmpty) return override;
    final root = AppPaths.findRepoRoot();
    if (root != null) return p.join(root, 'resect.config');
    return p.join(AppPaths.configDir, 'resect.config');
  }

  /// Load the config from [path] (or the resolved default). Missing file
  /// yields an empty config — never throws.
  static EnvConfig load([String? path]) {
    final cfgPath = path ?? resolveConfigPath();
    final values = <String, String>{};
    final file = File(cfgPath);
    if (file.existsSync()) {
      for (final raw in file.readAsLinesSync()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        final key = line.substring(0, eq).trim();
        var val = line.substring(eq + 1).trim();
        if (val.length >= 2 &&
            ((val.startsWith('"') && val.endsWith('"')) ||
                (val.startsWith("'") && val.endsWith("'")))) {
          val = val.substring(1, val.length - 1);
        }
        values[key] = val;
      }
    }
    return EnvConfig(cfgPath, values);
  }

  /// Raw string value for [key], or null if unset/blank.
  String? get(String key) {
    final v = _values[key];
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Boolean toggle (`1`/`true` = on). Defaults to [def] when unset.
  bool getBool(String key, {bool def = false}) {
    final v = _values[key];
    if (v == null) return def;
    return v == '1' || v.toLowerCase() == 'true';
  }

  void set(String key, String value) => _values[key] = value;
  void setBool(String key, bool value) => _values[key] = value ? '1' : '0';
  void remove(String key) => _values.remove(key);

  bool get exists => File(path).existsSync();
  Map<String, String> get all => Map.unmodifiable(_values);

  /// Whether the first-run setup wizard has been completed.
  bool get setupComplete => getBool('SETUP_DONE');

  /// Write the config back to [path] in a bash-sourceable, sorted form.
  Future<void> save() async {
    final buf = StringBuffer()
      ..writeln('# resect.config')
      ..writeln('# Generated and edited by the System Configuration UI.')
      ..writeln('# Sourced by install.sh / run.sh and read by the app. KEY="value".')
      ..writeln();
    final keys = _values.keys.toList()..sort();
    for (final k in keys) {
      buf.writeln('$k="${_values[k]}"');
    }
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(buf.toString());
  }
}
