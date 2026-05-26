import 'package:emulator_orchestrator/data/models/emulator.dart';
import '../../../../core/file_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Left rail of the Synthesize tab — emulator configuration.
///
/// Read-only firmware/platform paths, an editable execution range
/// (start-from / stop-at symbol pickers, pause-on-unhandled, memory map),
/// and the three hook groups (forced overrides / preferred / resolved).
class SynthesisConfigPanel extends ConsumerWidget {
  const SynthesisConfigPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    final isDirty = ref.watch(emulatorDirtyProvider);

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border(right: BorderSide(color: AppTheme.border)),
      ),
      child: emulator == null
          ? const _NoEmulator()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        emulator.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isDirty)
                      const Text(
                        'UNSAVED',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                const _SectionLabel('FIRMWARE'),
                _PathRow(path: emulator.elfFilePath),
                const SizedBox(height: 16),
                const _SectionLabel('PLATFORM'),
                _PathRow(path: emulator.baseImagePath),
                const SizedBox(height: 20),
                const Divider(height: 1, color: AppTheme.border),
                const SizedBox(height: 16),
                const _SectionLabel('EXECUTION RANGE'),
                const SizedBox(height: 8),
                _ConfigRow(
                  label: 'Start From',
                  value: emulator.emulationConfig.startFrom,
                  onTap: () => _pickSymbol(context, ref, emulator, start: true),
                  onClear: emulator.emulationConfig.startFrom != null
                      ? () => _updateConfig(ref, emulator, startFrom: '')
                      : null,
                ),
                _ConfigRow(
                  label: 'Stop At',
                  value: emulator.emulationConfig.endAt.isEmpty
                      ? null
                      : emulator.emulationConfig.endAt.join(', '),
                  onTap: () => _pickSymbol(context, ref, emulator, start: false),
                  onClear: emulator.emulationConfig.endAt.isNotEmpty
                      ? () => _updateConfig(ref, emulator, endAt: const [])
                      : null,
                ),
                _ConfigRow(
                  label: 'Memory Map',
                  value: _fileName(emulator.emulationConfig.memoryMapPath),
                  onTap: () => _pickMemoryMap(ref, emulator),
                  onClear: emulator.emulationConfig.memoryMapPath != null
                      ? () => _updateConfig(ref, emulator, memoryMapPath: '')
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 96,
                        child: Text(
                          'Pause on unhandled',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 12),
                        ),
                      ),
                      Text(
                        emulator.emulationConfig.pauseOnUnhandled ? 'on' : 'off',
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1, color: AppTheme.border),
                const SizedBox(height: 16),
                _HooksSection(emulator: emulator),
              ],
            ),
    );
  }

  String? _fileName(String? path) => path?.split('/').last;

  Future<void> _pickSymbol(
    BuildContext context,
    WidgetRef ref,
    Emulator emulator, {
    required bool start,
  }) async {
    final callGraph = ref.read(callgraphProvider).valueOrNull;
    if (callGraph == null || callGraph.symbols.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Load a firmware ELF first to select symbols')),
      );
      return;
    }
    final symbols = callGraph.symbols.keys.toList()..sort();
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _SymbolPickerDialog(
        symbols: symbols,
        title: start ? 'Start From' : 'Stop At',
      ),
    );
    if (selected == null) return;
    if (start) {
      _updateConfig(ref, emulator, startFrom: selected);
    } else {
      _updateConfig(ref, emulator, endAt: [selected]);
    }
  }

  Future<void> _pickMemoryMap(WidgetRef ref, Emulator emulator) async {
    final path = await ref.read(fileSelectorProvider).openFile(
          dialogTitle: 'Select Memory Map File',
          extensions: ['json'],
        );
    if (path == null) return;
    _updateConfig(ref, emulator, memoryMapPath: path);
  }

  /// Pass empty string to clear startFrom / memoryMapPath (copyWith treats
  /// null as "keep").
  void _updateConfig(
    WidgetRef ref,
    Emulator emulator, {
    String? startFrom,
    List<String>? endAt,
    String? memoryMapPath,
  }) {
    final clearStart = startFrom == '';
    final clearMap = memoryMapPath == '';
    final config = EmulationConfig(
      startFrom:
          clearStart ? null : (startFrom ?? emulator.emulationConfig.startFrom),
      endAt: endAt ?? emulator.emulationConfig.endAt,
      pauseOnUnhandled: emulator.emulationConfig.pauseOnUnhandled,
      memoryMapPath: clearMap
          ? null
          : (memoryMapPath ?? emulator.emulationConfig.memoryMapPath),
    );
    ref.read(currentEmulatorProvider.notifier).state =
        emulator.copyWith(emulationConfig: config, modifiedAt: DateTime.now());
    ref.read(emulatorDirtyProvider.notifier).state = true;
  }
}

class _NoEmulator extends StatelessWidget {
  const _NoEmulator();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Open an emulator from the Library tab to configure synthesis.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 2,
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  final String? path;
  const _PathRow({required this.path});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        path ?? '(none)',
        style: TextStyle(
          color: path == null ? AppTheme.textMuted : AppTheme.textPrimary,
          fontSize: 12,
          fontStyle: path == null ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _ConfigRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.bgCanvas,
                  border: Border.all(color: AppTheme.border),
                ),
                child: Text(
                  value ?? 'Set…',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: value == null
                        ? AppTheme.textMuted
                        : AppTheme.textPrimary,
                    fontSize: 12,
                    fontStyle:
                        value == null ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
            ),
          ),
          if (onClear != null)
            InkWell(
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 13, color: AppTheme.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _HooksSection extends ConsumerWidget {
  final Emulator emulator;
  const _HooksSection({required this.emulator});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref.watch(hookOverridesProvider);
    final preferences = ref.watch(hookPreferencesProvider);
    final resolved = emulator.hooks;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('HOOKS'),
        const SizedBox(height: 8),
        _HookGroup(
          label: 'Forced',
          color: const Color(0xFFE57373),
          symbols: overrides.keys.toList(),
          onTap: (s) => ref.read(selectedSymbolProvider.notifier).state = s,
        ),
        _HookGroup(
          label: 'Preferred',
          color: const Color(0xFFFFB74D),
          symbols: preferences.keys.toList(),
          onTap: (s) => ref.read(selectedSymbolProvider.notifier).state = s,
        ),
        _HookGroup(
          label: 'Resolved',
          color: const Color(0xFF81C784),
          symbols: resolved.keys.toList(),
          onTap: (s) => ref.read(selectedSymbolProvider.notifier).state = s,
        ),
        if (overrides.isEmpty && preferences.isEmpty && resolved.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'No hooks yet. Run synthesis to resolve them, or force one from '
              'the Call Graph metadata panel.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

class _HookGroup extends StatelessWidget {
  final String label;
  final Color color;
  final List<String> symbols;
  final ValueChanged<String> onTap;

  const _HookGroup({
    required this.label,
    required this.color,
    required this.symbols,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (symbols.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, color: color),
              const SizedBox(width: 6),
              Text(
                '$label (${symbols.length})',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ...symbols.map(
            (s) => InkWell(
              onTap: () => onTap(s),
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
                child: Text(
                  s,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SymbolPickerDialog extends StatefulWidget {
  final List<String> symbols;
  final String title;

  const _SymbolPickerDialog({required this.symbols, required this.title});

  @override
  State<_SymbolPickerDialog> createState() => _SymbolPickerDialogState();
}

class _SymbolPickerDialogState extends State<_SymbolPickerDialog> {
  final _controller = TextEditingController();
  late List<String> _filtered = widget.symbols;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _filter(String query) {
    setState(() {
      _filtered = query.isEmpty
          ? widget.symbols
          : widget.symbols
              .where((s) => s.toLowerCase().contains(query.toLowerCase()))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.bgPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select ${widget.title}',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _filter,
                style:
                    const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                cursorColor: AppTheme.accent,
                decoration: const InputDecoration(
                  hintText: 'Search symbols…',
                  hintStyle:
                      TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  prefixIcon:
                      Icon(Icons.search, size: 16, color: AppTheme.textMuted),
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.bgCanvas,
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: AppTheme.border),
                    borderRadius: BorderRadius.zero,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppTheme.border),
                    borderRadius: BorderRadius.zero,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppTheme.accent),
                    borderRadius: BorderRadius.zero,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_filtered.length} symbols',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) {
                    final symbol = _filtered[index];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(symbol),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 6, horizontal: 8),
                        child: Text(
                          symbol,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
