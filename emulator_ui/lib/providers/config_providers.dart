import 'package:emulator_orchestrator/config/component.dart';
import 'package:emulator_orchestrator/config/config_schema.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'package:emulator_orchestrator/config/component.dart';
export 'package:emulator_orchestrator/config/config_schema.dart';

/// Editable, in-memory view of `resect.config`.
class SystemConfigState {
  const SystemConfigState({
    required this.configPath,
    required this.values,
    required this.dirty,
  });

  final String configPath;
  final Map<String, String> values;
  final bool dirty;

  bool get setupComplete => values['SETUP_DONE'] == '1';

  SystemConfigState copyWith({Map<String, String>? values, bool? dirty}) =>
      SystemConfigState(
        configPath: configPath,
        values: values ?? this.values,
        dirty: dirty ?? this.dirty,
      );
}

class SystemConfigNotifier extends StateNotifier<SystemConfigState> {
  SystemConfigNotifier() : super(_load());

  static SystemConfigState _load() {
    final cfg = EnvConfig.load();
    return SystemConfigState(
      configPath: cfg.path,
      values: {...cfg.all},
      dirty: false,
    );
  }

  String value(String key) => state.values[key] ?? '';

  bool boolValue(String key, {bool def = false}) {
    final v = state.values[key];
    if (v == null) return def;
    return v == '1' || v.toLowerCase() == 'true';
  }

  void setValue(String key, String value) {
    final m = {...state.values}..[key] = value;
    state = state.copyWith(values: m, dirty: true);
  }

  void setBool(String key, bool value) => setValue(key, value ? '1' : '0');

  /// Fill any blank variable with its detected default.
  void fillDefaults() {
    final cfg = EnvConfig(state.configPath, {...state.values});
    final m = {...state.values};
    for (final v in configVariables) {
      if ((m[v.key] ?? '').isEmpty) {
        final d = detectDefault(v, cfg);
        if (d.isNotEmpty) m[v.key] = d;
      }
    }
    state = state.copyWith(values: m, dirty: true);
  }

  /// Recompute the detected default for a single variable.
  String detectFor(ConfigVariable v) =>
      detectDefault(v, EnvConfig(state.configPath, {...state.values}));

  Future<void> save({bool markSetupDone = false}) async {
    final cfg = EnvConfig(state.configPath, {...state.values});
    if (markSetupDone) cfg.set('SETUP_DONE', '1');
    await cfg.save();
    state = SystemConfigState(
      configPath: cfg.path,
      values: {...cfg.all},
      dirty: false,
    );
  }
}

final systemConfigProvider =
    StateNotifierProvider<SystemConfigNotifier, SystemConfigState>(
  (ref) => SystemConfigNotifier(),
);

/// True when the first-run setup wizard has not yet been completed.
final firstRunProvider = Provider<bool>((ref) => !ref.watch(systemConfigProvider).setupComplete);

/// Whether autosave is enabled (Tools ▸ Preferences). Backed by the
/// `PREF_AUTOSAVE` key in the repo-local `resect.config`.
final autosaveEnabledProvider = Provider<bool>(
  (ref) => ref.watch(systemConfigProvider).values['PREF_AUTOSAVE'] == '1',
);

/// The optional-module registry.
final componentRegistryProvider = Provider<List<Component>>(
  (ref) => buildComponentRegistry(),
);

/// Whether a given module (by config key) is enabled in the current config.
final moduleEnabledProvider = Provider.family<bool, String>((ref, configKey) => ref.watch(systemConfigProvider).values[configKey] == '1');

/// Live detection status for a component (by id).
final componentStatusProvider =
    FutureProvider.family<ComponentStatus, String>((ref, id) async {
  final component =
      ref.watch(componentRegistryProvider).firstWhere((c) => c.id == id);
  return component.detect();
});
