import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Left-rail symbols panel for the Call Graph tab.
///
/// Renders the current call graph's symbols grouped into Entry Points and
/// Isolated Nodes with a search box on top. Clicking a row updates
/// [selectedSymbolProvider], which drives the graph viewer and the
/// metadata panel.
class SymbolsPanel extends ConsumerStatefulWidget {
  const SymbolsPanel({super.key});

  @override
  ConsumerState<SymbolsPanel> createState() => _SymbolsPanelState();
}

class _SymbolsPanelState extends ConsumerState<SymbolsPanel> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callgraphAsync = ref.watch(callgraphProvider);

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border(right: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          _SearchBox(
            controller: _searchController,
            onChanged: (v) => setState(() => _query = v),
          ),
          Expanded(
            child: callgraphAsync.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Failed to load symbols: $e',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
              data: (cg) {
                if (cg == null) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No symbols yet',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  );
                }
                return _SymbolList(callGraph: cg, query: _query);
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: const Text(
        'SYMBOLS',
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 3,
        ),
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchBox({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 12),
        cursorColor: AppTheme.accent,
        decoration: InputDecoration(
          hintText: 'Search symbols…',
          hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          prefixIcon: const Icon(Icons.search,
              size: 14, color: AppTheme.textMuted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 28),
          isDense: true,
          filled: true,
          fillColor: AppTheme.bgCanvas,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          border: const OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.border),
            borderRadius: BorderRadius.zero,
          ),
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.border),
            borderRadius: BorderRadius.zero,
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: AppTheme.accent),
            borderRadius: BorderRadius.zero,
          ),
        ),
      ),
    );
  }
}

class _SymbolList extends ConsumerWidget {
  final CallGraph callGraph;
  final String query;

  const _SymbolList({required this.callGraph, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = _groupSymbols(callGraph, query.trim());
    final selected = ref.watch(selectedSymbolProvider);

    if (groups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No matches',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, i) {
        final item = groups[i];
        if (item is _Section) {
          return _SectionLabel(label: item.label, count: item.count);
        }
        if (item is _Sym) {
          final isSelected = item.name == selected;
          return _SymbolRow(
            name: item.name,
            selected: isSelected,
            onTap: () => ref.read(selectedSymbolProvider.notifier).state =
                item.name,
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  List<Object> _groupSymbols(CallGraph cg, String query) {
    final lower = query.toLowerCase();

    // Build caller relationships to find entry points / isolated nodes.
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};
    for (final entry in cg.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (final called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }

    final entryPoints = <String>[];
    final calledOnly = <String>[];
    final isolated = <String>[];

    for (final name in cg.symbols.keys) {
      if (!hasConnections.contains(name)) {
        isolated.add(name);
      } else if (!callers.containsKey(name) ||
          name.toLowerCase().contains('main') ||
          name.toLowerCase().contains('reset')) {
        entryPoints.add(name);
      } else {
        calledOnly.add(name);
      }
    }
    entryPoints.sort();
    calledOnly.sort();
    isolated.sort();

    bool matches(String s) =>
        lower.isEmpty || s.toLowerCase().contains(lower);

    final filteredEntryPoints = entryPoints.where(matches).toList();
    final filteredCalledOnly = calledOnly.where(matches).toList();
    final filteredIsolated = isolated.where(matches).toList();

    final out = <Object>[];
    if (filteredEntryPoints.isNotEmpty) {
      out.add(_Section('ENTRY POINTS', filteredEntryPoints.length));
      out.addAll(filteredEntryPoints.map((n) => _Sym(n)));
    }
    if (lower.isNotEmpty && filteredCalledOnly.isNotEmpty) {
      out.add(_Section('OTHER MATCHES', filteredCalledOnly.length));
      out.addAll(filteredCalledOnly.map((n) => _Sym(n)));
    }
    if (filteredIsolated.isNotEmpty) {
      out.add(_Section('ISOLATED', filteredIsolated.length));
      out.addAll(filteredIsolated.map((n) => _Sym(n)));
    }
    return out;
  }
}

class _Section {
  final String label;
  final int count;
  _Section(this.label, this.count);
}

class _Sym {
  final String name;
  _Sym(this.name);
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;

  const _SectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.textDisabled,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _SymbolRow extends StatelessWidget {
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _SymbolRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected ? AppTheme.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          name,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? AppTheme.textPrimary : AppTheme.textMuted,
            fontSize: 12,
            fontFamily: 'monospace',
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
