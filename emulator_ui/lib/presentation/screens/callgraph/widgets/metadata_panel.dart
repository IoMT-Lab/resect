import 'dart:async';

import 'package:emulator_orchestrator/data/database/artifact_database.dart' show Artifact;
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:emulator_orchestrator/data/services/scope_suggester.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/autosave_provider.dart';
import '../../../../providers/comms_config_providers.dart';

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
    final commsLockReason = _commsLockReasonFor(ref, symbolName);

    // Comms-classified symbols: show the effective override the Comms tab
    // is configuring for this symbol, read-only. The dropdown would just
    // sit empty + disabled here, which is misleading because the symbol
    // *is* being overridden — just not via this control.
    if (commsLockReason != null) {
      final emulator = ref.watch(currentEmulatorProvider);
      final assignment = emulator?.commsAssignments[symbolName];
      final configs = ref.watch(commsProtocolConfigProvider);
      final config =
          assignment == null ? null : configs[assignment.protocol];
      final label = assignment == null || config == null
          ? '—'
          : _commsHookLabel(assignment, config);
      return _ReadOnlyHookSlot(
        label: 'FORCE OVERRIDE',
        value: label,
        tooltip: commsLockReason,
      );
    }

    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final overrides = ref.watch(hookOverridesProvider);
    final overrideScopes = ref.watch(hookOverrideScopesProvider);
    final hasOverride = overrides[symbolName] != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HookDropdown(
          label: 'FORCE OVERRIDE',
          hint: 'None (no override)',
          hooksAsync: hooksAsync,
          selectedId: overrides[symbolName],
          disabledReason: null,
          onChanged: (artifactId) {
            final nextOverrides = Map<String, int>.from(overrides);
            final nextScopes = Map<String, String>.from(overrideScopes);
            if (artifactId == null) {
              nextOverrides.remove(symbolName);
              nextScopes.remove(symbolName);
            } else {
              nextOverrides[symbolName] = artifactId;
              // When picking an override fresh (no prior scope), pre-fill
              // the per-override scope with the name-derived suggestion so
              // what the user sees in the text field == what's saved.
              if (!nextScopes.containsKey(symbolName)) {
                final suggested = suggestScopeFromSymbol(symbolName);
                if (suggested.isNotEmpty) {
                  nextScopes[symbolName] = suggested;
                }
              }
            }
            ref.read(hookOverridesProvider.notifier).state = nextOverrides;
            ref.read(hookOverrideScopesProvider.notifier).state = nextScopes;
            _persistEmulator(
              ref,
              hookOverrides: nextOverrides,
              hookOverrideScopes: nextScopes,
            );
          },
        ),
        if (hasOverride) ...[
          const SizedBox(height: 10),
          _ScopeField(
            symbolName: symbolName,
            value: overrideScopes[symbolName] ?? '',
          ),
        ],
      ],
    );
  }
}

/// Per-override Renode scope text field. Visible only when an override is
/// selected. Persists every keystroke through [_persistEmulator]; empty
/// text removes the entry from [hookOverrideScopesProvider] (== no-scope
/// at apply time).
class _ScopeField extends ConsumerStatefulWidget {
  final String symbolName;
  final String value;

  const _ScopeField({required this.symbolName, required this.value});

  @override
  ConsumerState<_ScopeField> createState() => _ScopeFieldState();
}

class _ScopeFieldState extends ConsumerState<_ScopeField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _ScopeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // External writes (e.g. picking a different override → suggestion is
    // pre-filled) — sync the controller without disturbing the user's
    // cursor when the value is unchanged.
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
      _controller.selection =
          TextSelection.collapsed(offset: widget.value.length);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    final current = ref.read(hookOverrideScopesProvider);
    final next = Map<String, String>.from(current);
    if (text.isEmpty) {
      next.remove(widget.symbolName);
    } else {
      next[widget.symbolName] = text;
    }
    ref.read(hookOverrideScopesProvider.notifier).state = next;
    _persistEmulator(ref, hookOverrideScopes: next);
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _MutedLabel('SCOPE'),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.bgCanvas,
              border: Border.all(color: AppTheme.border),
            ),
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: InputBorder.none,
                hintText: 'unscoped',
                hintStyle: TextStyle(
                  color: AppTheme.textDisabled,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Renode hook scope. Empty = unscoped.',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      );
}

class _PreferredHookDropdown extends ConsumerWidget {
  final String symbolName;
  const _PreferredHookDropdown({required this.symbolName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commsLockReason = _commsLockReasonFor(ref, symbolName);

    // Comms-classified symbols skip synthesis iteration entirely (see B3) —
    // there's nothing for a preferred hook to influence. Surface that
    // directly rather than leaving a misleading empty disabled dropdown.
    if (commsLockReason != null) {
      return _ReadOnlyHookSlot(
        label: 'PREFERRED HOOK',
        value: 'Not applicable — comms-classified symbols skip synthesis '
            'iteration.',
        tooltip: commsLockReason,
        italic: true,
      );
    }

    final hooksAsync = ref.watch(hooksForSelectedSymbolProvider);
    final prefs = ref.watch(hookPreferencesProvider);

    return _HookDropdown(
      label: 'PREFERRED HOOK',
      hint: 'Auto (default order)',
      hooksAsync: hooksAsync,
      selectedId: prefs[symbolName],
      disabledReason: null,
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

/// Human-readable summary of the effective override for a comms-classified
/// symbol — derived from the symbol's assignment and the protocol's current
/// Comms-tab config. Matches the table in plan section B3.1.
String _commsHookLabel(CommsAssignment assignment, CommsProtocolConfig config) {
  final proto = assignment.protocol.name;
  if (!config.virtualized) {
    return 'none — $proto not virtualized';
  }
  switch (assignment.role) {
    case CommsRole.read:
      return '$proto read · UDP :${config.port}';
    case CommsRole.write:
      return '$proto write · UDP :${config.port}';
    case null:
      return config.fillUnmappedWithReturnZero
          ? 'return0 (fill-in)'
          : 'none — fill-in off';
  }
}

/// Static read-only slot used in place of the FORCE OVERRIDE / PREFERRED
/// HOOK dropdowns for comms-classified symbols. Reuses the existing slot
/// chrome (muted label + bordered container) so the layout is unchanged,
/// but the value is a plain text line — no chevron, no hover affordance.
/// The lock tooltip explains why it isn't interactive.
class _ReadOnlyHookSlot extends StatelessWidget {
  final String label;
  final String value;
  final String tooltip;
  final bool italic;

  const _ReadOnlyHookSlot({
    required this.label,
    required this.value,
    required this.tooltip,
    this.italic = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MutedLabel(label),
          const SizedBox(height: 6),
          Tooltip(
            message: tooltip,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.bgCanvas,
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline,
                      size: 13, color: AppTheme.textDisabled),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontStyle:
                            italic ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}

void _persistEmulator(
  WidgetRef ref, {
  Map<String, int>? hookOverrides,
  Map<String, int>? hookPreferences,
  Map<String, String>? hookOverrideScopes,
}) {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;
  ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
    hookOverrides: hookOverrides ?? emulator.hookOverrides,
    hookPreferences: hookPreferences ?? emulator.hookPreferences,
    hookOverrideScopes:
        hookOverrideScopes ?? emulator.hookOverrideScopes,
    modifiedAt: DateTime.now(),
  );
  ref.read(emulatorDirtyProvider.notifier).state = true;
  unawaited(ref.read(autosaveControllerProvider).trigger());
}

class _HookDropdown extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    // Distinguish loading/error states from genuinely-empty so the slot
    // doesn't claim "No hooks available" while the artifact library is
    // still topping up. The hooksAsync FutureProvider is gated on
    // artifactProcessingProvider; if that upstream hasn't resolved yet
    // (or errored), surface that directly. Only fall through to the
    // hooksAsync branches when the library has finished loading.
    final libraryAsync = ref.watch(artifactProcessingProvider);
    final libraryNotice = libraryAsync.when<Widget?>(
      loading: () => const Row(
        children: [
          SizedBox(
            height: 14,
            width: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          SizedBox(width: 8),
          Text(
            'Loading artifact library…',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
      error: (e, _) => Text(
        'Artifact library failed: $e',
        style: TextStyle(
          color: Colors.red.shade300,
          fontSize: 11,
          fontStyle: FontStyle.italic,
        ),
      ),
      data: (record) => record == null
          ? const Text(
              'No artifact library record for this firmware yet.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            )
          : null,
    );

    if (libraryNotice != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MutedLabel(label),
          const SizedBox(height: 6),
          libraryNotice,
        ],
      );
    }

    return Column(
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

            // Collapse rows with identical artifactData so the dropdown
            // shows one entry per distinct hook body. Earlier topup runs
            // may have left duplicate rows for a (symbol, body) pair; we
            // keep the lowest-id row as the canonical one.
            final byBody = <String, Artifact>{};
            for (final a in hooks) {
              final existing = byBody[a.artifactData];
              if (existing == null || a.id < existing.id) {
                byBody[a.artifactData] = a;
              }
            }
            final uniqueHooks = byBody.values.toList()
              ..sort((a, b) => a.id.compareTo(b.id));

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
                  ...uniqueHooks.map((artifact) => DropdownMenuItem<int?>(
                        value: artifact.id,
                        child: Text(
                          _hookLabel(artifact.artifactData),
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
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
  }

  String _hookLabel(String code) {
    final trimmed = code.trim();

    // Stateful variants from hooks-dart simple_hooks.dart (plan C1). Extract
    // the literal numeric parameter from the call site so the dropdown
    // distinguishes value=0 vs value=1 etc. Order matters: increment first
    // (its body also defines setVariable/getVariable), then write, then read.
    final incMatch =
        RegExp(r"incrementVariable\('value',\s*(-?\d+)").firstMatch(trimmed);
    if (incMatch != null) {
      return 'Stateful increment (from ${incMatch.group(1)})';
    }

    final setMatch =
        RegExp(r"setVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (setMatch != null) {
      return 'Stateful write (value ${setMatch.group(1)})';
    }

    final getMatch =
        RegExp(r"getVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (getMatch != null) {
      return 'Stateful read (default ${getMatch.group(1)})';
    }

    // Legacy pre-A2 `RegisterValue.Create(N, 64)` and the post-A2
    // `setReturnValue(cpu, N)` form are behaviorally identical — surface
    // them under the same label so the user isn't asked to distinguish
    // two rows that do the same thing.
    if (trimmed.contains('Create(0,')) return 'Return 0';
    if (trimmed.contains('Create(1,')) return 'Return 1';
    final returnMatch = RegExp(r'setReturnValue\(cpu,\s*(-?\d+)\)')
        .firstMatch(trimmed);
    if (returnMatch != null) {
      return 'Return ${returnMatch.group(1)}';
    }

    // Unrecognized — show a short preview of the last meaningful line.
    final lastLine = trimmed.split('\n').last.trim();
    return lastLine.length > 40 ? '${lastLine.substring(0, 37)}...' : lastLine;
  }
}
