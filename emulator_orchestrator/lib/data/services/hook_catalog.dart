import 'package:hooks/hooks.dart';
import 'package:renode/renode.dart';

/// Type tag for a [HookParamSpec] — keeps the UI rendering generic over kind
/// (a future parameter form widget can switch on this).
enum HookParamType { intValue, stringValue }

/// One parameter on a hook builder.
class HookParamSpec {
  final String name;
  final String label;
  final HookParamType type;
  final Object? defaultValue;

  const HookParamSpec({
    required this.name,
    required this.label,
    required this.type,
    this.defaultValue,
  });
}

/// Describes one buildable hook kind: a stable id, a label/description for UI,
/// the parameters it accepts, and a [build] that produces the renode [Hook]
/// (Python code + optional scope) via a hooks-dart builder.
///
/// New kinds plug in here either as new entries (parameterized over existing
/// hooks-dart builders) or — if more elaborate composition is needed — by
/// adding a new Python module to hooks-dart's `resources/python/` and a builder
/// that `import`s it. See [HookCatalog.system] for the seeded set.
class HookBuilderDescriptor {
  final String kindId;
  final String label;
  final String description;
  final List<HookParamSpec> parameters;
  final Hook Function(Map<String, dynamic> params) build;

  const HookBuilderDescriptor({
    required this.kindId,
    required this.label,
    required this.description,
    required this.parameters,
    required this.build,
  });
}

/// Registry of available hook builders.
///
/// Replaces the previous hand-written `return0HookCode`/`return1HookCode`
/// constants with hooks-dart-backed builders. The artifact DB still stores the
/// resulting code strings (no schema change); only the *source* of those
/// strings moves from hardcoded constants to `catalog.build(...).code`.
class HookCatalog {
  HookCatalog._(this._descriptors);

  final Map<String, HookBuilderDescriptor> _descriptors;

  /// All registered builders, in registration order.
  Iterable<HookBuilderDescriptor> get all => _descriptors.values;

  /// Look up a descriptor by [kindId], or `null` if unknown.
  HookBuilderDescriptor? descriptor(String kindId) => _descriptors[kindId];

  /// Build a hook by kind + params. Throws [ArgumentError] if [kindId] is
  /// unknown.
  Hook build(String kindId, [Map<String, dynamic> params = const {}]) {
    final d = _descriptors[kindId];
    if (d == null) {
      throw ArgumentError('Unknown hook kind: $kindId');
    }
    return d.build(params);
  }

  /// The seeded default catalog. Ensures hooks-dart's bundled Python modules
  /// are registered (idempotent), so hook code generates with inlined imports
  /// regardless of runtime (CLI, Flutter JIT, Flutter AOT).
  factory HookCatalog.system() {
    includeSystemModules();
    final descriptors = _systemDescriptors();
    return HookCatalog._({for (final d in descriptors) d.kindId: d});
  }

  /// Canonical default-hook code bodies, in the same order as
  /// [ArtifactLibraryService._defaultHookCodes]. Includes the two legacy
  /// `RegisterValue.Create(N, 64)` return bodies plus the catalog-built
  /// returnHook / readHook / writeHook / incrementHook variants. The UI
  /// uses this set to identify which DB rows are write-protected defaults.
  Set<String> defaultCodes() => {
        _legacyReturn0,
        _legacyReturn1,
        build('return', const {'value': 0}).code,
        build('return', const {'value': 1}).code,
        build('read', const {'scope': '', 'defaultValue': 0}).code,
        build('read', const {'scope': '', 'defaultValue': 1}).code,
        build('write', const {'scope': '', 'value': 0, 'returnValue': 0}).code,
        build('write', const {'scope': '', 'value': 1, 'returnValue': 0}).code,
        build('increment', const {'scope': '', 'defaultValue': 0}).code,
        build('increment', const {'scope': '', 'defaultValue': 1}).code,
      };

  static const _legacyReturn0 = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(0, 64))
cpu.PC = cpu.LR
''';
  static const _legacyReturn1 = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(1, 64))
cpu.PC = cpu.LR
''';
}

List<HookBuilderDescriptor> _systemDescriptors() => [
      HookBuilderDescriptor(
        kindId: 'return',
        label: 'Return constant',
        description:
            'Force the function to return a fixed integer (sets R0, jumps to '
            'LR). ARM-specific ABI — see arch-template TODO in the migration '
            'plan.',
        parameters: const [
          HookParamSpec(
            name: 'value',
            label: 'Return value',
            type: HookParamType.intValue,
            defaultValue: 0,
          ),
        ],
        build: (params) => returnHook(params['value'] as int? ?? 0),
      ),
      HookBuilderDescriptor(
        kindId: 'read',
        label: 'Stateful read',
        description:
            'Return a variable previously stored under the given scope. Pair '
            'with a "Stateful write" sharing the same scope. Requires the '
            'patched Renode portable for `scope` support.',
        parameters: const [
          HookParamSpec(
            name: 'scope',
            label: 'Scope',
            type: HookParamType.stringValue,
          ),
          HookParamSpec(
            name: 'defaultValue',
            label: 'Default',
            type: HookParamType.intValue,
            defaultValue: 0,
          ),
        ],
        build: (params) => readHook(
          params['scope'] as String,
          defaultValue: params['defaultValue'] as int? ?? 0,
        ),
      ),
      HookBuilderDescriptor(
        kindId: 'write',
        label: 'Stateful write',
        description:
            'Store a value under the given scope and return a status. Pair '
            'with a "Stateful read" sharing the same scope. Requires the '
            'patched Renode portable for `scope` support.',
        parameters: const [
          HookParamSpec(
            name: 'scope',
            label: 'Scope',
            type: HookParamType.stringValue,
          ),
          HookParamSpec(
            name: 'value',
            label: 'Value to write',
            type: HookParamType.intValue,
            defaultValue: 0,
          ),
          HookParamSpec(
            name: 'returnValue',
            label: 'Return value',
            type: HookParamType.intValue,
            defaultValue: 0,
          ),
        ],
        build: (params) => writeHook(
          params['scope'] as String,
          params['value'] as int? ?? 0,
          returnValue: params['returnValue'] as int? ?? 0,
        ),
      ),
      HookBuilderDescriptor(
        kindId: 'increment',
        label: 'Stateful increment',
        description:
            'Increment a variable under the given scope and return the new '
            'value. Requires the patched Renode portable for `scope` support.',
        parameters: const [
          HookParamSpec(
            name: 'scope',
            label: 'Scope',
            type: HookParamType.stringValue,
          ),
          HookParamSpec(
            name: 'defaultValue',
            label: 'Initial value',
            type: HookParamType.intValue,
            defaultValue: 0,
          ),
        ],
        build: (params) => incrementHook(
          params['scope'] as String,
          defaultValue: params['defaultValue'] as int? ?? 0,
        ),
      ),
      HookBuilderDescriptor(
        kindId: 'i2c_read',
        label: 'I2C read (bus-virtualized)',
        description:
            'Forward an I2C read transaction to the comms-bus UDP server on '
            'the given port. Used by Workstream B (comms-bus virtualization).',
        parameters: const [
          HookParamSpec(
            name: 'port',
            label: 'UDP port',
            type: HookParamType.intValue,
            defaultValue: 1234,
          ),
        ],
        // v1: hardcode the arch glue to 'stm32_glue'. Per the arch-aware
        // TODO in the plan, this becomes a parameter once non-STM glues
        // (nordic_glue.py, esp_idf_glue.py, …) exist.
        build: (params) =>
            i2cReadHook(params['port'] as int? ?? 1234, 'stm32_glue'),
      ),
      HookBuilderDescriptor(
        kindId: 'i2c_write',
        label: 'I2C write (bus-virtualized)',
        description:
            'Forward an I2C write transaction to the comms-bus UDP server on '
            'the given port. Used by Workstream B (comms-bus virtualization).',
        parameters: const [
          HookParamSpec(
            name: 'port',
            label: 'UDP port',
            type: HookParamType.intValue,
            defaultValue: 1234,
          ),
        ],
        build: (params) =>
            i2cWriteHook(params['port'] as int? ?? 1234, 'stm32_glue'),
      ),
      HookBuilderDescriptor(
        kindId: 'uart_read',
        label: 'UART read (bus-virtualized)',
        description:
            'Forward a UART read transaction to the comms-bus UDP server on '
            'the given port. Used by Workstream B (comms-bus virtualization).',
        parameters: const [
          HookParamSpec(
            name: 'port',
            label: 'UDP port',
            type: HookParamType.intValue,
            defaultValue: 1236,
          ),
        ],
        build: (params) =>
            uartReadHook(params['port'] as int? ?? 1236, 'stm32_glue'),
      ),
      HookBuilderDescriptor(
        kindId: 'uart_write',
        label: 'UART write (bus-virtualized)',
        description:
            'Forward a UART write transaction to the comms-bus UDP server on '
            'the given port. Used by Workstream B (comms-bus virtualization).',
        parameters: const [
          HookParamSpec(
            name: 'port',
            label: 'UDP port',
            type: HookParamType.intValue,
            defaultValue: 1236,
          ),
        ],
        build: (params) =>
            uartWriteHook(params['port'] as int? ?? 1236, 'stm32_glue'),
      ),
    ];
