import 'dart:async';

import 'package:emulator_orchestrator/data/database/artifact_database.dart' show Artifact;
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/autosave_provider.dart';

/// Right-rail metadata panel for the Call Graph tab.
///
/// Shows the currently selected symbol's details (instruction count,
/// callers, callees) plus inline editors for Force Override and Preferred
/// Hook. Clicking a caller or callee navigates by updating
/// [selectedSymbolProvider].
class MetadataPanel extends ConsumerWidget {
  const MetadataPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedSymbol = ref.watch(selectedSymbolProvider);
    final callgraphAsync = ref.watch(callgraphProvider);

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border(left: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          Expanded(
            child: selectedSymbol == null
                ? const _EmptyState()
                : callgraphAsync.when(
                    loading: () => const _CenteredSpinner(),
                    error: (e, _) => _ErrorBlock('Failed to load: $e'),
                    data: (cg) {
                      if (cg == null) return const _EmptyState();
                      final symbol = cg.getSymbol(selectedSymbol);
                      if (symbol == null) {
                        return const _ErrorBlock('Symbol not in call graph');
                      }
                      return _Details(
                        symbol: symbol,
                        callers: cg.getCallers(selectedSymbol),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: const Text(
        'METADATA',
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 3,
        ),
      ),
    );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Select a function in the graph or the Symbols list to view its details.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ),
    );
}

class _CenteredSpinner extends StatelessWidget {
  const _CenteredSpinner();

  @override
  Widget build(BuildContext context) => const Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      ),
    );
}

class _ErrorBlock extends StatelessWidget {
  final String message;
  const _ErrorBlock(this.message);

  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ),
    );
}

class _Details extends ConsumerWidget {
  final Symbol symbol;
  final List<String> callers;

  const _Details({required this.symbol, required this.callers});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const _MutedLabel('FUNCTION'),
        const SizedBox(height: 4),
        SelectableText(
          symbol.name,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 16),
        const _MutedLabel('INSTRUCTIONS'),
        const SizedBox(height: 4),
        Text(
          '${symbol.numInstructions}',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Divider(height: 1, color: AppTheme.border),
        const SizedBox(height: 16),
        _ForceOverrideDropdown(symbolName: symbol.name),
        const SizedBox(height: 14),
        _PreferredHookDropdown(symbolName: symbol.name),
        const SizedBox(height: 16),
        const Divider(height: 1, color: AppTheme.border),
        const SizedBox(height: 16),
        _MutedLabel('CALLS (${symbol.calledSymbols.length})'),
        const SizedBox(height: 6),
        if (symbol.calledSymbols.isEmpty)
          const Text(
            'No outgoing calls',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...symbol.calledSymbols.entries.map(
            (entry) => _LinkRow(
              icon: Icons.arrow_forward,
              name: entry.key,
              trailing: '×${entry.value}',
              onTap: () =>
                  ref.read(selectedSymbolProvider.notifier).state = entry.key,
            ),
          ),
        const SizedBox(height: 16),
        const Divider(height: 1, color: AppTheme.border),
        const SizedBox(height: 16),
        _MutedLabel('CALLED BY (${callers.length})'),
        const SizedBox(height: 6),
        if (callers.isEmpty)
          const Text(
            'No incoming calls',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...callers.map(
            (caller) => _LinkRow(
              icon: Icons.arrow_back,
              name: caller,
              onTap: () =>
                  ref.read(selectedSymbolProvider.notifier).state = caller,
            ),
          ),
      ],
    );
}

class _MutedLabel extends StatelessWidget {
  final String text;
  const _MutedLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
      text,
      style: const TextStyle(
        color: AppTheme.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
      ),
    );
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final String? trailing;
  final VoidCallback onTap;

  const _LinkRow({
    required this.icon,
    required this.name,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 11, color: AppTheme.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing!,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
}

// ---------------------------------------------------------------------------
// Hook dropdowns
// ---------------------------------------------------------------------------

class _ForceOverrideDropdown extends ConsumerWidget {
  final String symbolName;
  const _ForceOverrideDropdown({required this.symbolName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final overrides = ref.watch(hookOverridesProvider);
    final commsLockReason = _commsLockReasonFor(ref, symbolName);

    return _HookDropdown(
      label: 'FORCE OVERRIDE',
      hint: 'None (no override)',
      hooksAsync: hooksAsync,
      selectedId: overrides[symbolName],
      disabledReason: commsLockReason,
      onChanged: (artifactId) {
        final next = Map<String, int>.from(overrides);
        if (artifactId == null) {
          next.remove(symbolName);
        } else {
          next[symbolName] = artifactId;
        }
        ref.read(hookOverridesProvider.notifier).state = next;
        _persistEmulator(ref, hookOverrides: next);
      },
    );
  }
}

class _PreferredHookDropdown extends ConsumerWidget {
  final String symbolName;
  const _PreferredHookDropdown({required this.symbolName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final prefs = ref.watch(hookPreferencesProvider);
    final commsLockReason = _commsLockReasonFor(ref, symbolName);

    return _HookDropdown(
      label: 'PREFERRED HOOK',
      hint: 'Auto (default order)',
      hooksAsync: hooksAsync,
      selectedId: prefs[symbolName],
      disabledReason: commsLockReason,
      onChanged: (artifactId) {
        final next = Map<String, int>.from(prefs);
        if (artifactId == null) {
          next.remove(symbolName);
        } else {
          next[symbolName] = artifactId;
        }
        ref.read(hookPreferencesProvider.notifier).state = next;
        _persistEmulator(ref, hookPreferences: next);
      },
    );
  }
}

/// Returns a tooltip explaining why the override/preferred dropdowns are
/// locked for [symbolName], or `null` if the symbol is overridable normally.
///
/// Per the Workstream B precedence rule: a symbol classified into a real
/// comms class (i2c / spi / uart, not `unclassified`) is non-overridable;
/// the debug path is to reclassify it to `unclassified` in the Comms tab.
String? _commsLockReasonFor(WidgetRef ref, String symbolName) {
  final assignment = ref.watch(currentEmulatorProvider)?.commsAssignments[symbolName];
  if (assignment == null) return null;
  switch (assignment.protocol) {
    case CommsClass.i2c:
    case CommsClass.spi:
    case CommsClass.uart:
      return 'Comms-classified (${assignment.protocol.name}). '
          'Reclassify to "unclassified" in the Comms tab to override.';
    case CommsClass.unclassified:
      return null;
  }
}

void _persistEmulator(
  WidgetRef ref, {
  Map<String, int>? hookOverrides,
  Map<String, int>? hookPreferences,
}) {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;
  ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
    hookOverrides: hookOverrides ?? emulator.hookOverrides,
    hookPreferences: hookPreferences ?? emulator.hookPreferences,
    modifiedAt: DateTime.now(),
  );
  ref.read(emulatorDirtyProvider.notifier).state = true;
  unawaited(ref.read(autosaveControllerProvider).trigger());
}

class _HookDropdown extends StatelessWidget {
  final String label;
  final String hint;
  final AsyncValue<List<Artifact>> hooksAsync;
  final int? selectedId;
  final ValueChanged<int?> onChanged;

  /// When non-null, the dropdown is rendered disabled (DropdownButton's
  /// `onChanged: null` form) and wrapped in a tooltip showing this string.
  /// Used to surface the Comms-classified non-overridable rule.
  final String? disabledReason;

  const _HookDropdown({
    required this.label,
    required this.hint,
    required this.hooksAsync,
    required this.selectedId,
    required this.onChanged,
    this.disabledReason,
  });

  @override
  Widget build(BuildContext context) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MutedLabel(label),
        const SizedBox(height: 6),
        hooksAsync.when(
          loading: () => const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          error: (e, _) => Text(
            'Error: $e',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
          data: (hooks) {
            if (hooks.isEmpty) {
              return const Text(
                'No hooks available',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                ),
              );
            }

            final isLocked = disabledReason != null;
            final dropdown = Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: AppTheme.bgCanvas,
                border: Border.all(color: AppTheme.border),
              ),
              child: DropdownButton<int?>(
                value: selectedId,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                dropdownColor: AppTheme.bgPanel,
                icon: const Icon(Icons.expand_more, size: 16),
                iconEnabledColor: AppTheme.textMuted,
                iconDisabledColor: AppTheme.textDisabled,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                ),
                hint: Text(
                  hint,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                  ),
                ),
                items: [
                  DropdownMenuItem<int?>(
                    value: null,
                    child: Text(
                      hint,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  ...hooks.asMap().entries.map((entry) {
                    final index = entry.key;
                    final artifact = entry.value;
                    return DropdownMenuItem<int?>(
                      value: artifact.id,
                      child: Text(
                        _hookLabel(index, artifact.artifactData),
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }),
                ],
                // null onChanged disables DropdownButton.
                onChanged: isLocked ? null : onChanged,
              ),
            );
            return isLocked
                ? Tooltip(message: disabledReason!, child: dropdown)
                : dropdown;
          },
        ),
      ],
    );

  String _hookLabel(int index, String code) {
    final trimmed = code.trim();
    if (trimmed.contains('Create(0,')) return 'Hook ${index + 1}: return 0';
    if (trimmed.contains('Create(1,')) return 'Hook ${index + 1}: return 1';
    final lastLine = trimmed.split('\n').last.trim();
    final preview = lastLine.length > 40
        ? '${lastLine.substring(0, 37)}...'
        : lastLine;
    return 'Hook ${index + 1}: $preview';
  }
}
