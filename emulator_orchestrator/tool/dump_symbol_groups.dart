// Diagnostic: run the SymbolGroupClassifier over a saved project's call-graph
// symbols and print the object groups it finds. Usage:
//   dart run tool/dump_symbol_groups.dart "<path to .emu>"
import 'dart:io';

import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/dump_symbol_groups.dart <path.emu>');
    exit(2);
  }
  final emu = await EmulatorRepository().loadEmulator(args.first);
  final symbols = emu.cachedCallGraph?.symbols.keys.toList() ?? const [];
  final comms = emu.commsAssignments.keys.toSet();

  final groups = SymbolGroupClassifier(catalog: HookCatalog.system())
      .classify(symbols, exclude: comms);

  final grouped = groups.fold<int>(0, (n, g) => n + g.members.length);
  stdout.writeln('Firmware: ${emu.name}');
  stdout.writeln('Symbols: ${symbols.length}  ·  comms-excluded: ${comms.length}');
  stdout.writeln('Object groups: ${groups.length}  ·  '
      'symbols in a group: $grouped');
  stdout.writeln('');

  // Largest groups first, then alphabetical.
  final sorted = [...groups]..sort((a, b) {
      final byN = b.members.length.compareTo(a.members.length);
      return byN != 0 ? byN : a.scope.compareTo(b.scope);
    });
  for (final g in sorted) {
    stdout.writeln('◆ ${g.scope}  (${g.members.length})');
    final entries = g.members.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final e in entries) {
      final role = e.value.role.name;
      final action = _hookAction(role);
      stdout.writeln('    ${e.key.padRight(42)} $role${action.isEmpty ? '' : '  → $action'}');
    }
    stdout.writeln('');
  }
}

String _hookAction(String role) {
  switch (role) {
    case 'enable':
    case 'set':
      return 'write 1';
    case 'disable':
    case 'reset':
    case 'clear':
      return 'write 0';
    case 'isReady':
    case 'get':
      return 'read';
    case 'init':
    case 'deinit':
      return 'return 0';
    default:
      return ''; // unknown → no coherent hook
  }
}
