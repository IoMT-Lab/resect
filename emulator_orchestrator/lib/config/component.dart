import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config_schema.dart' show which;

enum ComponentKind { required, optional }

/// Live detection result for a component (computed, never persisted).
class ComponentStatus {
  const ComponentStatus(this.available, this.detail);

  /// True when the component's prerequisites are present on this machine.
  final bool available;

  /// Short human-readable status, shown next to the toggle.
  final String detail;
}

class ComponentInstallException implements Exception {
  ComponentInstallException(this.message);
  final String message;
  @override
  String toString() => 'ComponentInstallException: $message';
}

/// An optional add-on module surfaced in the System Configuration UI. Enable
/// flags live in `resect.config` under [configKey]; detection is live.
abstract class Component {
  String get id;
  String get title;
  String get description;
  ComponentKind get kind;
  String get configKey;

  /// Whether [install] performs real (user-level) provisioning work.
  bool get installable;

  /// Probe the machine for this component's prerequisites.
  Future<ComponentStatus> detect();

  /// Run user-level installation, emitting progress lines. Adds an error to
  /// the stream (or throws) on failure. No-op components complete immediately.
  Stream<String> install();
}

/// LLM-assisted hook generation via a local Ollama + Gemma model.
class LlmHookGenComponent extends Component {
  static const _model = 'gemma3';

  @override
  String get id => 'llm_hookgen';
  @override
  String get title => 'LLM Hook Generation';
  @override
  String get description =>
      'Generate hook code with a local Ollama + Gemma model.';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_LLM_HOOKGEN';
  @override
  bool get installable => true;

  @override
  Future<ComponentStatus> detect() async {
    final ollama = which('ollama');
    if (ollama == null) {
      return const ComponentStatus(false, 'Ollama not installed');
    }
    try {
      final r = await Process.run(ollama, ['list']);
      final hasModel = (r.stdout as String).contains(_model);
      return ComponentStatus(
        hasModel,
        hasModel
            ? 'Ollama + $_model ready'
            : 'Ollama present — model "$_model" not pulled',
      );
    } catch (_) {
      return const ComponentStatus(false, 'Ollama present but not responding');
    }
  }

  @override
  Stream<String> install() async* {
    final ollama = which('ollama');
    if (ollama == null) {
      throw ComponentInstallException(
        'Ollama is not installed. Install it from https://ollama.com, '
        'then retry. (System packages are out of scope for in-app install.)',
      );
    }
    yield 'Pulling model "$_model" via Ollama…';
    final proc = await Process.start(ollama, ['pull', _model]);
    final lines = StreamController<String>();
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: lines.addError);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onError: lines.addError);
    unawaited(proc.exitCode.then((_) => lines.close()));
    yield* lines.stream;
    final code = await proc.exitCode;
    if (code != 0) {
      throw ComponentInstallException('`ollama pull` exited with code $code');
    }
    yield 'Model "$_model" ready.';
  }
}

/// Memory-map initialization module (pure-Dart; gates the memory-map picker in
/// Synthesize and defines the constants/regions applied to a fresh machine).
class MemoryMapComponent extends Component {
  @override
  String get id => 'memory_map';
  @override
  String get title => 'Memory Map Initialization';
  @override
  String get description =>
      'Apply a memory-map (constants/regions) snapshot before emulation.';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_MEMORY_MAP';
  @override
  bool get installable => false;

  @override
  Future<ComponentStatus> detect() async =>
      const ComponentStatus(true, 'Built-in');

  @override
  Stream<String> install() async* {
    yield 'Enabled.';
  }
}

/// Communication-bus virtualization module (gates the Comms tab where I2C/SPI/
/// UART functions are mapped to software implementations).
class CommsBusComponent extends Component {
  @override
  String get id => 'comms_bus';
  @override
  String get title => 'Communication Bus Virtualization';
  @override
  String get description =>
      'Map I2C/SPI/UART functions to software implementations (Comms tab).';
  @override
  ComponentKind get kind => ComponentKind.optional;
  @override
  String get configKey => 'MODULE_COMMS_BUS';
  @override
  bool get installable => false;

  @override
  Future<ComponentStatus> detect() async =>
      const ComponentStatus(true, 'Built-in');

  @override
  Stream<String> install() async* {
    yield 'Enabled.';
  }
}

/// The v1 optional-module registry.
List<Component> buildComponentRegistry() => [
      LlmHookGenComponent(),
      MemoryMapComponent(),
      CommsBusComponent(),
    ];
