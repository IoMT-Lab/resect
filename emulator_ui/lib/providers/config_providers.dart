import 'dart:async';

import 'package:emulator_orchestrator/config/component.dart';
import 'package:emulator_orchestrator/config/config_schema.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/services/ghidra_installer.dart';
import 'package:emulator_orchestrator/data/services/ollama_installer.dart';
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

/// Singleton [OllamaInstaller] shared across the app's lifetime. The
/// `onDispose` hook (fired when the ProviderContainer tears down)
/// sends SIGTERM to the locally-spawned `ollama serve` so we don't
/// leak that process when Resect closes.
final ollamaInstallerProvider = Provider<OllamaInstaller>((ref) {
  final installer = OllamaInstaller();
  // Riverpod's `onDispose` is synchronous, but `stopDaemon` is async.
  // Fire-and-forget via `unawaited`: SIGTERM-then-SIGKILL inside
  // `stopDaemon` takes at most ~3 s and races against the app tearing
  // down. The daemon process won't outlive Resect either way (kernel
  // reparents it to PID 1, but Resect's own `serve` got SIGTERM).
  ref.onDispose(() => unawaited(installer.stopDaemon()));
  return installer;
});

/// Singleton [GhidraInstaller] shared across the app's lifetime.
/// Ghidra doesn't run a persistent daemon (every extraction is a
/// one-shot `analyzeHeadless` invocation), so unlike
/// [ollamaInstallerProvider] there's nothing to tear down on
/// dispose — but we still want one instance so the install-progress
/// stream isn't restarted every time `componentStatusProvider`
/// re-detects.
final ghidraInstallerProvider =
    Provider<GhidraInstaller>((ref) => GhidraInstaller());

/// The optional-module registry. Each opt-in module shares its
/// singleton installer via the providers above so the registry can
/// rebuild (when `componentStatusProvider` re-detects, etc.)
/// without orphaning install state.
final componentRegistryProvider = Provider<List<Component>>(
  (ref) => buildComponentRegistry(
    installer: ref.watch(ollamaInstallerProvider),
    ghidraInstaller: ref.watch(ghidraInstallerProvider),
  ),
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

/// Inference-capable model tags currently installed in the managed
/// Ollama daemon (filters out the embed model). Used by the LLM
/// module card's active-model picker. Returns an empty list when
/// Ollama isn't installed yet — the UI then hides the picker.
final installedInferenceModelsProvider =
    FutureProvider<List<String>>((ref) async {
  final llm = ref
      .watch(componentRegistryProvider)
      .whereType<LlmHookGenComponent>()
      .firstOrNull;
  if (llm == null) return const [];
  // Re-fetch whenever the component status changes (e.g. just after
  // an install dialog closed). Otherwise the dropdown would show
  // stale data until manual refresh.
  await ref.watch(componentStatusProvider(llm.id).future);
  return llm.installedInferenceModels();
});
