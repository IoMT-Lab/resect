import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/comms_config_providers.dart';

/// COMMS tab — bus virtualization workspace.
///
/// Layout (mirrors the Call Graph toolbar pattern for the class selector):
/// - Top bar with a class-selector dropdown (i2c / spi / uart / unclassified).
/// - Two-pane main area:
///   - Left: functions assigned to the selected class. Each row exposes the
///     detected role and lets the user assign it explicitly or reassign the
///     symbol to a different class.
///   - Right: Python interface (UDP port + device handler + Virtualize
///     toggle). Hidden for `unclassified` since that bucket has no protocol.
///
/// Bus-hook application and the UDP server lifecycle live in B3/B4 — for
/// this slice the Virtualize toggle records intent but does not yet apply
/// hooks or start a server.
class CommsScreen extends ConsumerWidget {
  const CommsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    final assignments = emulator?.commsAssignments ?? const {};

    if (emulator == null) {
      return const _EmptyState(
        message: 'Open a project to use the Comms workspace.',
      );
    }
    if (assignments.isEmpty) {
      return const _EmptyState(
        message:
            'No comms functions detected yet. Load a call graph; classification '
            'runs at call-graph construction time.',
      );
    }

    final selected = ref.watch(selectedCommsClassProvider);
    final showRightPane = selected != CommsClass.unclassified;

    return Column(
      children: [
        _ClassSelectorBar(selected: selected, assignments: assignments),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: showRightPane ? 3 : 1,
                child: _FunctionsPane(selected: selected, assignments: assignments),
              ),
              if (showRightPane) ...[
                const VerticalDivider(width: 1, color: AppTheme.border),
                Expanded(
                  flex: 2,
                  child: _PythonInterfacePane(selected: selected),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ClassSelectorBar extends ConsumerWidget {
  final CommsClass selected;
  final Map<String, CommsAssignment> assignments;
  const _ClassSelectorBar({required this.selected, required this.assignments});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = <CommsClass, int>{
      for (final c in CommsClass.values) c: 0,
    };
    for (final a in assignments.values) {
      counts[a.protocol] = (counts[a.protocol] ?? 0) + 1;
    }

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppTheme.bgChrome,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cable_outlined, size: 16, color: AppTheme.textMuted),
          const SizedBox(width: 10),
          const Text(
            'Class:',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<CommsClass>(
              value: selected,
              dropdownColor: AppTheme.bgPanel,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              items: [
                for (final c in CommsClass.values)
                  DropdownMenuItem(
                    value: c,
                    child: Text('${_classLabel(c)}  (${counts[c]})'),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  ref.read(selectedCommsClassProvider.notifier).state = v;
                }
              },
            ),
          ),
          const Spacer(),
          Text(
            '${assignments.length} comms function${assignments.length == 1 ? '' : 's'} total',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _FunctionsPane extends ConsumerWidget {
  final CommsClass selected;
  final Map<String, CommsAssignment> assignments;
  const _FunctionsPane({required this.selected, required this.assignments});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filtered = assignments.entries
        .where((e) => e.value.protocol == selected)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    if (filtered.isEmpty) {
      return _EmptyState(
        message: 'No functions in ${_classLabel(selected)}.',
      );
    }

    return Container(
      color: AppTheme.bgCanvas,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: filtered.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, color: AppTheme.border),
        itemBuilder: (context, i) {
          final entry = filtered[i];
          return _FunctionRow(symbol: entry.key, assignment: entry.value);
        },
      ),
    );
  }
}

class _FunctionRow extends ConsumerWidget {
  final String symbol;
  final CommsAssignment assignment;
  const _FunctionRow({required this.symbol, required this.assignment});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                symbol,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            _RoleControl(symbol: symbol, assignment: assignment),
            const SizedBox(width: 12),
            _ReassignButton(symbol: symbol, currentClass: assignment.protocol),
          ],
        ),
      );
}

class _RoleControl extends ConsumerWidget {
  final String symbol;
  final CommsAssignment assignment;
  const _RoleControl({required this.symbol, required this.assignment});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      DropdownButtonHideUnderline(
        child: DropdownButton<CommsRole?>(
          value: assignment.role,
          dropdownColor: AppTheme.bgPanel,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 11),
          isDense: true,
          hint: const Text(
            '— (assign role)',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          items: const [
            DropdownMenuItem(value: null, child: Text('—')),
            DropdownMenuItem(value: CommsRole.read, child: Text('read')),
            DropdownMenuItem(value: CommsRole.write, child: Text('write')),
          ],
          onChanged: (v) => _updateAssignment(
            ref,
            symbol,
            assignment.copyWith(role: v, clearRole: v == null),
          ),
        ),
      );
}

class _ReassignButton extends ConsumerWidget {
  final String symbol;
  final CommsClass currentClass;
  const _ReassignButton(
      {required this.symbol, required this.currentClass});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      PopupMenuButton<CommsClass>(
        icon: const Icon(Icons.swap_horiz, size: 16, color: AppTheme.textMuted),
        tooltip: 'Reassign to class',
        color: AppTheme.bgPanel,
        itemBuilder: (context) => [
          for (final c in CommsClass.values)
            if (c != currentClass)
              PopupMenuItem(
                value: c,
                child: Text(
                  _classLabel(c),
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 12),
                ),
              ),
        ],
        onSelected: (newClass) {
          // Moving to unclassified clears the role (no protocol → no role).
          // Other moves preserve the role if set; user can re-pick after.
          final current = ref.read(currentEmulatorProvider)?.commsAssignments[symbol];
          if (current == null) return;
          final next = CommsAssignment(
            protocol: newClass,
            role: newClass == CommsClass.unclassified ? null : current.role,
          );
          _updateAssignment(ref, symbol, next);
        },
      );
}

class _PythonInterfacePane extends ConsumerWidget {
  final CommsClass selected;
  const _PythonInterfacePane({required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(commsProtocolConfigProvider);
    final config = configs[selected] ?? const CommsProtocolConfig();

    return Container(
      color: AppTheme.bgPanel,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'PYTHON INTERFACE — ${_classLabel(selected).toUpperCase()}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'All ${''}functions assigned to this class share one Renode scope; '
            'multi-bus identity is carried via HID in the wire protocol.',
            style: TextStyle(
                color: AppTheme.textMuted, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 24),
          _ConfigField(
            label: 'UDP port',
            child: SizedBox(
              width: 100,
              child: TextFormField(
                initialValue: config.port.toString(),
                keyboardType: TextInputType.number,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final port = int.tryParse(v);
                  if (port == null) return;
                  _updateConfig(
                      ref, selected, config.copyWith(port: port));
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          _ConfigField(
            label: 'Device handler',
            child: DropdownButtonHideUnderline(
              child: DropdownButton<CommsDeviceHandlerKind>(
                value: config.handler,
                dropdownColor: AppTheme.bgPanel,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 12),
                items: [
                  for (final h in CommsDeviceHandlerKind.values)
                    DropdownMenuItem(value: h, child: Text(h.label)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _updateConfig(
                      ref, selected, config.copyWith(handler: v));
                },
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Switch(
                value: config.virtualized,
                onChanged: (v) => _updateConfig(
                    ref, selected, config.copyWith(virtualized: v)),
              ),
              const SizedBox(width: 8),
              Text(
                'Virtualize ${_classLabel(selected)}',
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Bus-hook application and the in-process UDP server are wired up '
            'in B3/B4. For now this toggle records intent only.',
            style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _ConfigField extends StatelessWidget {
  final String label;
  final Widget child;
  const _ConfigField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          child,
        ],
      );
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        color: AppTheme.bgCanvas,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 13, height: 1.5),
          ),
        ),
      );
}

String _classLabel(CommsClass c) {
  switch (c) {
    case CommsClass.i2c:
      return 'I2C';
    case CommsClass.spi:
      return 'SPI';
    case CommsClass.uart:
      return 'UART';
    case CommsClass.unclassified:
      return 'unclassified';
  }
}

void _updateAssignment(WidgetRef ref, String symbol, CommsAssignment next) {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;
  final updated = Map<String, CommsAssignment>.from(emulator.commsAssignments);
  updated[symbol] = next;
  ref.read(currentEmulatorProvider.notifier).state =
      emulator.copyWith(commsAssignments: updated);
  ref.read(emulatorDirtyProvider.notifier).state = true;
}

void _updateConfig(
    WidgetRef ref, CommsClass cls, CommsProtocolConfig next) {
  final current = ref.read(commsProtocolConfigProvider);
  final updated = Map<CommsClass, CommsProtocolConfig>.from(current);
  updated[cls] = next;
  ref.read(commsProtocolConfigProvider.notifier).state = updated;
}
