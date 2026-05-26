import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/file_selection.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';

import '../../providers/app_providers.dart';

/// Dialog for viewing, importing, and deleting hook artifacts.
///
/// Shows a flat, searchable list of all hooks for the current firmware.
/// Default hooks (return 0 / return 1) cannot be deleted.
class HookDatabaseDialog extends ConsumerStatefulWidget {
  const HookDatabaseDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => const HookDatabaseDialog(),
    );
  }

  @override
  ConsumerState<HookDatabaseDialog> createState() => _HookDatabaseDialogState();
}

class _HookDatabaseDialogState extends ConsumerState<HookDatabaseDialog> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // Import form state
  bool _importExpanded = false;
  String? _importSymbol;
  bool _importFromFile = false;
  final _codeController = TextEditingController();
  String? _pickedFilePath;
  bool _importing = false;

  // Expanded hook ID (for viewing code)
  int? _expandedHookId;

  @override
  void dispose() {
    _searchController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool _isDefaultHook(String code) {
    final trimmed = code.trim();
    return trimmed.contains('Create(0,') || trimmed.contains('Create(1,');
  }

  String _hookLabel(String code) {
    final trimmed = code.trim();
    if (trimmed.contains('Create(0,')) return 'return 0';
    if (trimmed.contains('Create(1,')) return 'return 1';
    final lastLine = trimmed.split('\n').last.trim();
    return lastLine.length > 40 ? '${lastLine.substring(0, 37)}...' : lastLine;
  }

  Future<void> _deleteHook(int artifactId) async {
    final db = ref.read(artifactDatabaseProvider);
    await db.deleteArtifact(artifactId);

    // Clean up preferences referencing this artifact
    final prefs = Map<String, int>.from(ref.read(hookPreferencesProvider));
    prefs.removeWhere((_, id) => id == artifactId);
    ref.read(hookPreferencesProvider.notifier).state = prefs;

    // Clean up overrides referencing this artifact
    final ovrs = Map<String, int>.from(ref.read(hookOverridesProvider));
    ovrs.removeWhere((_, id) => id == artifactId);
    ref.read(hookOverridesProvider.notifier).state = ovrs;

    // Update emulator model
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator != null) {
      ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
        hookPreferences: prefs,
        hookOverrides: ovrs,
        modifiedAt: DateTime.now(),
      );
      ref.read(emulatorDirtyProvider.notifier).state = true;
    }

    // Refresh providers
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
  }

  Future<void> _importHook() async {
    if (_importSymbol == null) return;

    setState(() => _importing = true);

    try {
      String code;
      if (_importFromFile && _pickedFilePath != null) {
        code = await File(_pickedFilePath!).readAsString();
      } else {
        code = _codeController.text;
      }

      if (code.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hook code cannot be empty')),
          );
        }
        return;
      }

      final db = ref.read(artifactDatabaseProvider);
      final firmwareRecord = ref.read(artifactProcessingProvider).valueOrNull;
      if (firmwareRecord == null) return;

      final symbol = await db.getSymbol(firmwareRecord.elfHash, _importSymbol!);
      if (symbol == null) return;

      await db.addArtifact(
        symbolId: symbol.id,
        artifactType: 'renode_hook',
        artifactData: code,
      );

      // Refresh providers
      ref.invalidate(allHooksForFirmwareProvider);
      ref.invalidate(hooksForSelectedSymbolProvider);

      // Reset import form
      setState(() {
        _codeController.clear();
        _pickedFilePath = null;
        _importExpanded = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hook imported for $_importSymbol')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _pickPyFile() async {
    final path = await ref.read(fileSelectorProvider).openFile(
          dialogTitle: 'Select Hook File',
          extensions: ['py'],
        );
    if (path == null) return;
    setState(() => _pickedFilePath = path);
  }

  @override
  Widget build(BuildContext context) {
    final allHooksAsync = ref.watch(allHooksForFirmwareProvider);
    final firmwareRecord = ref.watch(artifactProcessingProvider).valueOrNull;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row
              Row(
                children: [
                  const Icon(Icons.storage, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Hook Database',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (firmwareRecord != null)
                    Text(
                      '${firmwareRecord.symbolNames.length} symbols',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(),

              // Search bar
              TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search symbols or code...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
              const SizedBox(height: 8),

              // Hook list
              Expanded(
                child: allHooksAsync.when(
                  data: (allHooks) => _buildHookList(allHooks),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(child: Text('Error: $e')),
                ),
              ),

              // Import panel
              const Divider(),
              _buildImportPanel(firmwareRecord),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHookList(
      List<({String symbolName, Artifact artifact})> allHooks) {
    final filtered = allHooks.where((h) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return h.symbolName.toLowerCase().contains(q) ||
          h.artifact.artifactData.toLowerCase().contains(q);
    }).toList();

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isEmpty ? 'No hooks found' : 'No matches',
          style: TextStyle(color: Colors.grey.shade500),
        ),
      );
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final item = filtered[index];
        final showHeader = index == 0 ||
            filtered[index - 1].symbolName != item.symbolName;
        final isDefault = _isDefaultHook(item.artifact.artifactData);
        final isExpanded = _expandedHookId == item.artifact.id;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showHeader) _buildSymbolHeader(item.symbolName),
            _buildHookRow(item.artifact, item.symbolName, isDefault, isExpanded),
          ],
        );
      },
    );
  }

  Widget _buildSymbolHeader(String symbolName) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        symbolName,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildHookRow(
      Artifact artifact, String symbolName, bool isDefault, bool isExpanded) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _expandedHookId = isExpanded ? null : artifact.id;
            });
          },
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 14,
                  color: Colors.grey.shade500,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _hookLabel(artifact.artifactData),
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '#${artifact.id}',
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade300),
                  ),
                ),
                if (isDefault) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade900.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'DEFAULT',
                      style: TextStyle(
                          fontSize: 8,
                          color: Colors.blue.shade200,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                if (!isDefault)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 16, color: Colors.red.shade400),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Delete hook',
                    onPressed: () => _deleteHook(artifact.id),
                  )
                else
                  const SizedBox(width: 16),
              ],
            ),
          ),
        ),
        // Expanded code view
        if (isExpanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(left: 30, right: 12, bottom: 4),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: SelectableText(
              artifact.artifactData.trim(),
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImportPanel(dynamic firmwareRecord) {
    if (!_importExpanded) {
      return TextButton.icon(
        onPressed: firmwareRecord != null
            ? () => setState(() => _importExpanded = true)
            : null,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Import Hook'),
      );
    }

    final symbolNames =
        (firmwareRecord as dynamic)?.symbolNames as List<String>? ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Import Hook',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => setState(() {
                _importExpanded = false;
                _codeController.clear();
                _pickedFilePath = null;
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Symbol selector
        DropdownButtonFormField<String>(
          value: _importSymbol,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Symbol',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          items: symbolNames.map((name) {
            return DropdownMenuItem(value: name, child: Text(name, style: const TextStyle(fontSize: 12)));
          }).toList(),
          onChanged: (v) => setState(() => _importSymbol = v),
        ),
        const SizedBox(height: 8),

        // Paste / File toggle
        Row(
          children: [
            ChoiceChip(
              label: const Text('Paste Code', style: TextStyle(fontSize: 11)),
              selected: !_importFromFile,
              onSelected: (_) =>
                  setState(() => _importFromFile = false),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Pick .py File', style: TextStyle(fontSize: 11)),
              selected: _importFromFile,
              onSelected: (_) =>
                  setState(() => _importFromFile = true),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Code input or file picker
        if (!_importFromFile)
          SizedBox(
            height: 100,
            child: TextField(
              controller: _codeController,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Paste Python hook code here...',
                hintStyle: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600),
                isDense: true,
                contentPadding: const EdgeInsets.all(8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  _pickedFilePath != null
                      ? _pickedFilePath!.split('/').last
                      : 'No file selected',
                  style: TextStyle(
                    fontSize: 12,
                    color: _pickedFilePath != null
                        ? null
                        : Colors.grey.shade500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _pickPyFile,
                child: const Text('Browse', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        const SizedBox(height: 8),

        // Import button
        ElevatedButton(
          onPressed: _importing ||
                  _importSymbol == null ||
                  (!_importFromFile && _codeController.text.trim().isEmpty) ||
                  (_importFromFile && _pickedFilePath == null)
              ? null
              : _importHook,
          child: _importing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Import'),
        ),
      ],
    );
  }
}
