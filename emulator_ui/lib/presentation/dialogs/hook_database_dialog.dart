import 'dart:async';

import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/target_arch.dart';
import 'package:emulator_orchestrator/data/services/hook_test_harness.dart';
import 'package:emulator_orchestrator/data/services/starter_template.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/autosave_provider.dart';
import '../../providers/config_providers.dart';
import 'hook_test_result_dialog.dart';
import 'llm_hook_gen_dialog.dart';

/// Hook-centric viewer + editor over the artifact pool.
///
/// Under the v2 schema the pool is tiny: ~10 global default templates,
/// plus however many user-authored hooks have been created (each
/// targeted at one specific (firmware, symbol)). Per-symbol selection
/// lives in `Emulator.hookOverrides`, not in the DB — so this dialog
/// shows one row per artifact, no aggregation needed.
class HookDatabaseDialog extends ConsumerStatefulWidget {
  const HookDatabaseDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => const HookDatabaseDialog(),
      );

  @override
  ConsumerState<HookDatabaseDialog> createState() =>
      _HookDatabaseDialogState();
}

enum _Mode { viewing, creating }

/// Whether a newly-authored hook is reusable (any symbol can pick it
/// up via the synthesizer) or a replacement (authored for one
/// specific function).
enum _HookKind { reusable, replacement }

class _HookDatabaseDialogState extends ConsumerState<HookDatabaseDialog> {
  final _searchController = TextEditingController();
  final _codeController = TextEditingController();

  var _searchQuery = '';
  var _hideDefaults = false;

  /// Currently selected artifact. Null when nothing selected or in
  /// creating mode.
  Artifact? _selected;

  /// New-hook form state (creating mode).
  final _newHookNameController = TextEditingController();
  String? _newHookArchitecture;
  _HookKind _newHookKind = _HookKind.reusable;
  String? _newHookTargetSymbol;

  /// Pulled from [archRegistry] so adding a new architecture is one
  /// line of [target_arch.dart], not a UI-side hardcode. The values
  /// are `TargetArch.id` strings — same shape the hooks-DB
  /// `architecture` column stores.
  static final _architectureChoices = <String>[
    for (final arch in archRegistry.values) arch.id,
  ];

  _Mode _mode = _Mode.viewing;
  var _isDirty = false;

  @override
  void dispose() {
    _searchController.dispose();
    _codeController.dispose();
    _newHookNameController.dispose();
    super.dispose();
  }

  bool _isDefault(Artifact a) => a.origin == 'default';

  void _selectArtifact(Artifact a) {
    setState(() {
      _selected = a;
      _mode = _Mode.viewing;
      _codeController.text = a.artifactData;
      _isDirty = false;
    });
  }

  void _startNewHook() {
    // Pre-select the architecture matching the loaded ELF's
    // e_machine; fall back to the first registry entry (ARM
    // Cortex-M) when no ELF is loaded yet or the machine isn't
    // in our registry.
    final machine =
        ref.read(artifactProcessingProvider).valueOrNull?.machine;
    final preselectedArch =
        targetArchFor(machine)?.id ?? _architectureChoices.first;
    setState(() {
      _selected = null;
      _newHookNameController.clear();
      _newHookArchitecture = preselectedArch;
      _newHookKind = _HookKind.reusable;
      _newHookTargetSymbol = null;
      _mode = _Mode.creating;
      _codeController.clear();
      _isDirty = false;
    });
  }

  /// Prepend the annotated starter template to the New Hook code
  /// editor. The functional bytes come from the catalog's
  /// `returnHook(0)` (single-source ABI), wrapped with a
  /// plain-language header that explains what a hook is and marks
  /// the editable line. See
  /// [emulator_orchestrator/lib/data/services/starter_template.dart].
  ///
  /// One-way: no removal counterpart — users delete lines manually.
  /// No-op when the buffer already starts with the template header.
  void _insertStarterTemplate() {
    if (_codeController.text
        .trimLeft()
        .startsWith(starterTemplatePrefix)) {
      return;
    }
    setState(() {
      _codeController.text = '${starterTemplate()}\n${_codeController.text}';
      _isDirty = _codeController.text.trim().isNotEmpty;
    });
  }

  /// Open the LLM hook-generation dialog. On Accept, replace the code
  /// buffer with the generated body. RAG context comes from the
  /// currently selected target symbol (when in Replacement mode) and
  /// its callers/callees from the cached call graph.
  Future<void> _generateWithLlm() async {
    final emulator = ref.read(currentEmulatorProvider);
    final graph = emulator?.cachedCallGraph;
    final target = _newHookKind == _HookKind.replacement
        ? _newHookTargetSymbol
        : null;
    final callers = (target != null && graph != null)
        ? graph.getCallers(target)
        : const <String>[];
    final callees = (target != null && graph != null)
        ? (graph.getSymbol(target)?.calledSymbols.keys.toList() ??
            const <String>[])
        : const <String>[];
    final result = await LlmHookGenDialog.show(
      context,
      targetSymbol: target,
      targetCallers: callers,
      targetCallees: callees,
    );
    if (result == null || result.trim().isEmpty) return;
    setState(() {
      _codeController.text = result;
      _isDirty = true;
    });
  }

  void _onCodeChanged(String value) {
    final base = _mode == _Mode.creating ? '' : (_selected?.artifactData ?? '');
    final next = value != base;
    if (next != _isDirty) setState(() => _isDirty = next);
  }

  String _archFromBody(String code) {
    if (code.contains('cpu.SetRegister(') &&
        code.contains('cpu.PC = cpu.LR')) {
      return 'ARM';
    }
    return '';
  }

  String _hookLabel(String code) {
    final trimmed = code.trim();
    final inc = RegExp(r"incrementVariable\('value',\s*(-?\d+)")
        .firstMatch(trimmed);
    if (inc != null) return 'Stateful increment (from ${inc.group(1)})';
    final set = RegExp(r"setVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (set != null) return 'Stateful write (value ${set.group(1)})';
    final get = RegExp(r"getVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (get != null) return 'Stateful read (default ${get.group(1)})';
    if (trimmed.contains('Create(0,')) return 'Return 0';
    if (trimmed.contains('Create(1,')) return 'Return 1';
    final ret = RegExp(r'setReturnValue\(cpu,\s*(-?\d+)\)').firstMatch(trimmed);
    if (ret != null) return 'Return ${ret.group(1)}';
    final lastLine = trimmed.split('\n').last.trim();
    return lastLine.length > 40 ? '${lastLine.substring(0, 37)}…' : lastLine;
  }

  /// Count of `hookOverrides` entries in the current emulator that
  /// reference [artifactId]. Surfaces "how many symbols are pinned to
  /// this hook right now."
  int _overrideUseCount(int artifactId) {
    final overs = ref.read(hookOverridesProvider);
    return overs.values.where((id) => id == artifactId).length;
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    String confirm = 'Continue',
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgPanel,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Future<void> _save() async {
    final selected = _selected;
    if (selected == null || _isDefault(selected)) return;
    final edited = _codeController.text;
    if (edited == selected.artifactData) return;
    final db = ref.read(artifactDatabaseProvider);
    await db.updateArtifactData(id: selected.id, artifactData: edited);
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
    if (!mounted) return;
    setState(() {
      _selected = Artifact(
        id: selected.id,
        artifactType: selected.artifactType,
        artifactData: edited,
        origin: selected.origin,
        name: selected.name,
        architecture: selected.architecture,
        targetSymbolName: selected.targetSymbolName,
        createdAt: selected.createdAt,
      );
      _isDirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Hook #${selected.id} updated')),
    );
  }

  Future<void> _saveAsNew() async {
    final selected = _selected;
    if (selected == null) return;
    final edited = _codeController.text.trim();
    if (edited.isEmpty) return;

    // Prompt for the new hook's name + architecture + kind. Pre-fill
    // from the source: keep the name (with " (copy)" suffix when
    // forking a user hook), the architecture, and the kind+target if
    // the source was itself a replacement.
    final defaultName = selected.name != null
        ? '${selected.name} (copy)'
        : _hookLabel(selected.artifactData);
    final defaultArch = selected.architecture ?? _archFromBody(edited);
    final defaultKind = selected.targetSymbolName != null
        ? _HookKind.replacement
        : _HookKind.reusable;
    final firmware = ref.read(artifactProcessingProvider).valueOrNull;
    final result = await _promptNameAndArch(
      title: 'Save as new hook',
      initialName: defaultName,
      initialArchitecture: defaultArch,
      initialKind: defaultKind,
      initialTargetSymbol: selected.targetSymbolName,
      symbolNames: firmware?.symbolNames ?? const [],
    );
    if (result == null) return;

    final db = ref.read(artifactDatabaseProvider);
    final newId = await db.addArtifact(
      artifactType: selected.artifactType,
      artifactData: edited,
      origin: 'user',
      name: result.name,
      architecture: result.architecture,
      targetSymbolName: result.targetSymbolName,
    );
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
    if (!mounted) return;
    final created = await db.getArtifactById(newId);
    if (created != null && mounted) _selectArtifact(created);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isDefault(selected)
            ? 'New hook #$newId created — default left unchanged'
            : 'Forked to new hook #$newId'),
      ),
    );
  }

  Future<void> _createNewHook() async {
    final name = _newHookNameController.text.trim();
    if (name.isEmpty) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    final target = _newHookKind == _HookKind.replacement
        ? _newHookTargetSymbol
        : null;
    if (_newHookKind == _HookKind.replacement && target == null) return;
    final db = ref.read(artifactDatabaseProvider);
    final newId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: code,
      origin: 'user',
      name: name,
      architecture: _newHookArchitecture,
      targetSymbolName: target,
    );
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
    if (!mounted) return;
    final created = await db.getArtifactById(newId);
    if (created != null && mounted) _selectArtifact(created);
    if (!mounted) return;
    final suffix = target == null ? '' : ' (replaces $target)';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created hook #$newId: $name$suffix')),
    );
  }

  Future<void> _delete() async {
    final selected = _selected;
    if (selected == null || _isDefault(selected)) return;
    final useCount = _overrideUseCount(selected.id);
    final ok = await _confirm(
      title: 'Delete hook #${selected.id}?',
      body: useCount == 0
          ? 'This hook is not currently set as an override on any symbol.'
          : 'This hook is currently overriding $useCount '
              'symbol${useCount == 1 ? '' : 's'}. Those override'
              '${useCount == 1 ? '' : 's'} will be cleared.',
      confirm: 'Delete',
    );
    if (!ok) return;
    final db = ref.read(artifactDatabaseProvider);
    await db.deleteArtifact(selected.id);

    // Scrub references in preferences / overrides / scopes.
    final prefs = Map<String, int>.from(ref.read(hookPreferencesProvider))
      ..removeWhere((_, id) => id == selected.id);
    ref.read(hookPreferencesProvider.notifier).state = prefs;

    final overs = Map<String, int>.from(ref.read(hookOverridesProvider))
      ..removeWhere((_, id) => id == selected.id);
    ref.read(hookOverridesProvider.notifier).state = overs;

    final scopes =
        Map<String, String>.from(ref.read(hookOverrideScopesProvider))
          ..removeWhere((sym, _) => !overs.containsKey(sym));
    ref.read(hookOverrideScopesProvider.notifier).state = scopes;

    final emulator = ref.read(currentEmulatorProvider);
    if (emulator != null) {
      ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
        hookPreferences: prefs,
        hookOverrides: overs,
        hookOverrideScopes: scopes,
        modifiedAt: DateTime.now(),
      );
      ref.read(emulatorDirtyProvider.notifier).state = true;
      unawaited(ref.read(autosaveControllerProvider).trigger());
    }
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
    if (!mounted) return;
    setState(() {
      _selected = null;
      _codeController.clear();
      _isDirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Hook #${selected.id} deleted')),
    );
  }

  /// Run the hook currently in the code editor against the bundled
  /// minimal test firmware and show the result. Tests the buffer
  /// contents, not the saved artifact body — so the user can iterate
  /// on edits without saving first.
  Future<void> _runTest() async {
    final selected = _selected;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to test — code editor is empty.')),
      );
      return;
    }
    final harness = ref.read(hookTestHarnessProvider);
    final label = selected?.name ?? _hookLabel(code);

    // Modal progress dialog while the harness spins up Renode.
    final progress = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TestProgressDialog(),
    );
    HookTestResult? result;
    try {
      result = await harness.runHook(hookCode: code);
    } catch (e) {
      result = HookTestResult(
        returnValues: const [],
        ranToCompletion: false,
        errorMessage: 'Harness failed to launch: $e',
        runtime: Duration.zero,
        renodeLogTail: '',
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await progress;
    }
    if (!mounted) return;
    await HookTestResultDialog.show(
      context,
      hookLabel: label,
      result: result,
      onRerun: _runTest,
    );
  }

  Future<void> _reseedDefaults() async {
    final ok = await _confirm(
      title: 'Reseed default templates?',
      body: 'Any default-template rows whose body no longer matches the '
          "catalog's current output will be replaced with the canonical "
          'body. Overrides that referenced the obsolete rows will be '
          'remapped to the survivor for the same hook kind.',
      confirm: 'Reseed',
    );
    if (!ok) return;
    final service = ref.read(artifactLibraryServiceProvider);
    final remap = await service.reseedDefaults();
    if (remap.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Defaults already up to date.')),
      );
      return;
    }
    // Remap overrides + preferences.
    final overs = Map<String, int>.from(ref.read(hookOverridesProvider))
      ..updateAll((_, id) => remap[id] ?? id);
    ref.read(hookOverridesProvider.notifier).state = overs;
    final prefs = Map<String, int>.from(ref.read(hookPreferencesProvider))
      ..updateAll((_, id) => remap[id] ?? id);
    ref.read(hookPreferencesProvider.notifier).state = prefs;

    final emulator = ref.read(currentEmulatorProvider);
    if (emulator != null) {
      ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
        hookPreferences: prefs,
        hookOverrides: overs,
        modifiedAt: DateTime.now(),
      );
      ref.read(emulatorDirtyProvider.notifier).state = true;
      unawaited(ref.read(autosaveControllerProvider).trigger());
    }
    ref.invalidate(allHooksForFirmwareProvider);
    ref.invalidate(hooksForSelectedSymbolProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Replaced ${remap.length} obsolete templates')),
    );
  }

  Future<
      ({
        String name,
        String? architecture,
        String? targetSymbolName,
      })?> _promptNameAndArch({
    required String title,
    required String initialName,
    required String? initialArchitecture,
    _HookKind initialKind = _HookKind.reusable,
    String? initialTargetSymbol,
    List<String> symbolNames = const [],
  }) async {
    final nameCtl = TextEditingController(text: initialName);
    String? arch =
        _architectureChoices.contains(initialArchitecture)
            ? initialArchitecture
            : null;
    var kind = initialKind;
    var target = initialTargetSymbol;
    final result = await showDialog<
        ({
          String name,
          String? architecture,
          String? targetSymbolName,
        })>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final canSave = nameCtl.text.trim().isNotEmpty &&
              (kind == _HookKind.reusable || target != null);
          // Rebuild Save-button enablement as the name field changes.
          void onNameChanged() => setLocal(() {});
          nameCtl
            ..removeListener(onNameChanged)
            ..addListener(onNameChanged);
          return AlertDialog(
            backgroundColor: AppTheme.bgPanel,
            title: Text(title),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kind',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  _KindSelector(
                    kind: kind,
                    onChanged: (v) => setLocal(() {
                      kind = v;
                      if (v == _HookKind.reusable) target = null;
                    }),
                  ),
                  if (kind == _HookKind.replacement) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Target function',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    _SymbolPicker(
                      symbols: symbolNames,
                      value: target,
                      onChanged: (v) => setLocal(() => target = v),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Name',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: nameCtl,
                    autofocus: true,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 12),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide:
                              const BorderSide(color: AppTheme.border)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Architecture',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.bgCanvas,
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: arch,
                        isExpanded: true,
                        hint: const Text(
                          'Any',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 12),
                        ),
                        dropdownColor: AppTheme.bgPanel,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 12),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Any'),
                          ),
                          for (final a in _architectureChoices)
                            DropdownMenuItem(value: a, child: Text(a)),
                        ],
                        onChanged: (v) => setLocal(() => arch = v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: canSave
                    ? () {
                        final n = nameCtl.text.trim();
                        if (n.isEmpty) return;
                        Navigator.of(ctx).pop((
                          name: n,
                          architecture: arch,
                          targetSymbolName:
                              kind == _HookKind.replacement ? target : null,
                        ));
                      }
                    : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    nameCtl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final allHooksAsync = ref.watch(allHooksForFirmwareProvider);
    final firmware = ref.watch(artifactProcessingProvider).valueOrNull;

    return Dialog(
      backgroundColor: AppTheme.bgPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(firmware: firmware),
            const Divider(height: 1, color: AppTheme.border),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 4,
                    child: _LeftPane(
                      allHooksAsync: allHooksAsync,
                      searchController: _searchController,
                      searchQuery: _searchQuery,
                      hideDefaults: _hideDefaults,
                      onSearch: (v) => setState(() => _searchQuery = v),
                      onToggleHideDefaults: (v) =>
                          setState(() => _hideDefaults = v),
                      selectedId: _selected?.id,
                      onSelect: _selectArtifact,
                      onNewHook: _startNewHook,
                      onReseed: _reseedDefaults,
                      isDefault: _isDefault,
                      hookLabel: _hookLabel,
                      archFromBody: _archFromBody,
                      overrideUseCount: _overrideUseCount,
                    ),
                  ),
                  const VerticalDivider(width: 1, color: AppTheme.border),
                  Expanded(
                    flex: 6,
                    child: _RightPane(
                      mode: _mode,
                      selected: _selected,
                      newHookNameController: _newHookNameController,
                      newHookArchitecture: _newHookArchitecture,
                      onPickNewArchitecture: (v) =>
                          setState(() => _newHookArchitecture = v),
                      architectureChoices: _architectureChoices,
                      newHookKind: _newHookKind,
                      onPickNewKind: (k) => setState(() {
                        _newHookKind = k;
                        if (k == _HookKind.reusable) {
                          _newHookTargetSymbol = null;
                        }
                      }),
                      newHookTargetSymbol: _newHookTargetSymbol,
                      onPickNewTargetSymbol: (s) =>
                          setState(() => _newHookTargetSymbol = s),
                      symbolNames: firmware?.symbolNames ?? const [],
                      onInsertStarter: _insertStarterTemplate,
                      onGenerateWithLlm: _generateWithLlm,
                      codeController: _codeController,
                      isDirty: _isDirty,
                      onCodeChanged: _onCodeChanged,
                      isDefault: _isDefault,
                      hookLabel: _hookLabel,
                      archFromBody: _archFromBody,
                      overrideUseCount: _overrideUseCount,
                      onSave: _save,
                      onSaveAsNew: _saveAsNew,
                      onDelete: _delete,
                      onTest: _runTest,
                      onCreate: _createNewHook,
                      onCancelCreate: () => setState(() {
                        _mode = _Mode.viewing;
                        _codeController.clear();
                        _isDirty = false;
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final dynamic firmware;
  const _Header({required this.firmware});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.storage, size: 18, color: AppTheme.textPrimary),
            const SizedBox(width: 10),
            const Text(
              'HOOK DATABASE',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const Spacer(),
            if (firmware != null)
              Text(
                '${(firmware.symbolNames as List).length} symbols  ·  '
                'firmware ${(firmware.elfHash as String).substring(0, 8)}…',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              color: AppTheme.textMuted,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
}

class _LeftPane extends StatelessWidget {
  final AsyncValue<List<Artifact>> allHooksAsync;
  final TextEditingController searchController;
  final String searchQuery;
  final bool hideDefaults;
  final ValueChanged<String> onSearch;
  final ValueChanged<bool> onToggleHideDefaults;
  final int? selectedId;
  final void Function(Artifact) onSelect;
  final VoidCallback onNewHook;
  final Future<void> Function() onReseed;
  final bool Function(Artifact) isDefault;
  final String Function(String) hookLabel;
  final String Function(String) archFromBody;
  final int Function(int) overrideUseCount;

  const _LeftPane({
    required this.allHooksAsync,
    required this.searchController,
    required this.searchQuery,
    required this.hideDefaults,
    required this.onSearch,
    required this.onToggleHideDefaults,
    required this.selectedId,
    required this.onSelect,
    required this.onNewHook,
    required this.onReseed,
    required this.isDefault,
    required this.hookLabel,
    required this.archFromBody,
    required this.overrideUseCount,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: searchController,
              onChanged: onSearch,
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Search labels, code, or symbols…',
                hintStyle: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12),
                prefixIcon: const Icon(Icons.search,
                    size: 16, color: AppTheme.textMuted),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppTheme.border)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppTheme.border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: AppTheme.accent)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Checkbox(
                  value: hideDefaults,
                  onChanged: (v) => onToggleHideDefaults(v ?? false),
                  visualDensity: VisualDensity.compact,
                ),
                const Text(
                  'Hide defaults',
                  style:
                      TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onReseed,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Reseed defaults',
                      style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textMuted,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: onNewHook,
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('New hook',
                      style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: allHooksAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('Error: $e',
                    style: const TextStyle(color: AppTheme.textMuted)),
              ),
              data: (all) {
                final q = searchQuery.toLowerCase();
                final filtered = all.where((a) {
                  if (hideDefaults && isDefault(a)) return false;
                  if (q.isEmpty) return true;
                  if (a.artifactData.toLowerCase().contains(q)) return true;
                  if (hookLabel(a.artifactData).toLowerCase().contains(q)) {
                    return true;
                  }
                  if ((a.name ?? '').toLowerCase().contains(q)) return true;
                  if ((a.targetSymbolName ?? '')
                      .toLowerCase()
                      .contains(q)) {
                    return true;
                  }
                  return false;
                }).toList()
                  ..sort((a, b) {
                    // Defaults first, then by id (creation order).
                    final ad = isDefault(a) ? 0 : 1;
                    final bd = isDefault(b) ? 0 : 1;
                    if (ad != bd) return ad.compareTo(bd);
                    return a.id.compareTo(b.id);
                  });

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text(
                      'No hooks match.',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 12),
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final a = filtered[i];
                    final selected = a.id == selectedId;
                    return _ArtifactRow(
                      artifact: a,
                      selected: selected,
                      isDefault: isDefault(a),
                      label: hookLabel(a.artifactData),
                      arch: archFromBody(a.artifactData),
                      overrideUses: overrideUseCount(a.id),
                      onTap: () => onSelect(a),
                    );
                  },
                );
              },
            ),
          ),
        ],
      );
}

class _ArtifactRow extends StatelessWidget {
  final Artifact artifact;
  final bool selected;
  final bool isDefault;
  final String label;
  final String arch;
  final int overrideUses;
  final VoidCallback onTap;

  const _ArtifactRow({
    required this.artifact,
    required this.selected,
    required this.isDefault,
    required this.label,
    required this.arch,
    required this.overrideUses,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? AppTheme.accent.withValues(alpha: 0.15)
        : Colors.transparent;
    final subtitleParts = <String>[
      if (artifact.name != null) artifact.name!,
      if (artifact.targetSymbolName != null)
        'Replacement for ${artifact.targetSymbolName}',
      if (overrideUses > 0)
        '$overrideUses active override${overrideUses == 1 ? '' : 's'}',
    ];
    return Material(
      color: bg,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.bgCanvas,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Text(
                  '#${artifact.id}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 9,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join('  ·  '),
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (arch.isNotEmpty)
                _Pill(text: arch, color: const Color(0xFF81C784)),
              const SizedBox(width: 4),
              if (isDefault)
                const _Pill(text: 'DEFAULT', color: Color(0xFFFFB74D))
              else
                const _Pill(text: 'USER', color: Color(0xFF4FC3F7)),
              if (artifact.targetSymbolName != null) ...[
                const SizedBox(width: 4),
                const _Pill(
                  text: 'REPLACEMENT',
                  color: Color(0xFFBA68C8),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );
}

class _RightPane extends StatelessWidget {
  final _Mode mode;
  final Artifact? selected;
  final TextEditingController newHookNameController;
  final String? newHookArchitecture;
  final ValueChanged<String?> onPickNewArchitecture;
  final List<String> architectureChoices;
  final _HookKind newHookKind;
  final ValueChanged<_HookKind> onPickNewKind;
  final String? newHookTargetSymbol;
  final ValueChanged<String?> onPickNewTargetSymbol;
  final List<String> symbolNames;
  final VoidCallback onInsertStarter;
  final Future<void> Function() onGenerateWithLlm;
  final TextEditingController codeController;
  final bool isDirty;
  final ValueChanged<String> onCodeChanged;
  final bool Function(Artifact) isDefault;
  final String Function(String) hookLabel;
  final String Function(String) archFromBody;
  final int Function(int) overrideUseCount;
  final Future<void> Function() onSave;
  final Future<void> Function() onSaveAsNew;
  final Future<void> Function() onDelete;
  final Future<void> Function() onTest;
  final Future<void> Function() onCreate;
  final VoidCallback onCancelCreate;

  const _RightPane({
    required this.mode,
    required this.selected,
    required this.newHookNameController,
    required this.newHookArchitecture,
    required this.onPickNewArchitecture,
    required this.architectureChoices,
    required this.newHookKind,
    required this.onPickNewKind,
    required this.newHookTargetSymbol,
    required this.onPickNewTargetSymbol,
    required this.symbolNames,
    required this.onInsertStarter,
    required this.onGenerateWithLlm,
    required this.codeController,
    required this.isDirty,
    required this.onCodeChanged,
    required this.isDefault,
    required this.hookLabel,
    required this.archFromBody,
    required this.overrideUseCount,
    required this.onSave,
    required this.onSaveAsNew,
    required this.onDelete,
    required this.onTest,
    required this.onCreate,
    required this.onCancelCreate,
  });

  @override
  Widget build(BuildContext context) {
    if (mode == _Mode.creating) return _buildCreating();
    final s = selected;
    if (s == null) {
      return const Center(
        child: Text(
          'Select a hook on the left, or create a new one.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      );
    }
    return _buildViewing(context, s);
  }

  Widget _buildViewing(BuildContext context, Artifact s) {
    final isDef = isDefault(s);
    final canSave = isDirty && !isDef;
    final canSaveAsNew = isDirty && codeController.text.trim().isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ViewingHeader(
            artifact: s,
            label: hookLabel(s.artifactData),
            arch: archFromBody(s.artifactData),
            overrideUses: overrideUseCount(s.id),
            isDefault: isDef,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _CodeField(
              controller: codeController,
              onChanged: onCodeChanged,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!isDef)
                OutlinedButton.icon(
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline,
                      size: 14, color: Colors.red.shade300),
                  label: Text('Delete',
                      style: TextStyle(color: Colors.red.shade300)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.red.shade300),
                  ),
                ),
              if (!isDef) const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onTest,
                icon: const Icon(Icons.play_arrow, size: 14),
                label: const Text('Test'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.border),
                ),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: canSaveAsNew ? onSaveAsNew : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.border),
                ),
                child: const Text('Save As New'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: canSave ? onSave : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  disabledBackgroundColor:
                      AppTheme.accent.withValues(alpha: 0.3),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Save'),
              ),
            ],
          ),
          if (isDef)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Write-protected default template. Edits go through '
                '"Save As New" — the default itself stays untouched.',
                style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCreating() => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Listen to the name controller so the Create button enables
          // as soon as a non-empty name is typed.
          void rebuildOnText() => setLocal(() {});
          newHookNameController.removeListener(rebuildOnText);
          newHookNameController.addListener(rebuildOnText);

          final canCreate = newHookNameController.text.trim().isNotEmpty &&
              codeController.text.trim().isNotEmpty &&
              (newHookKind == _HookKind.reusable ||
                  newHookTargetSymbol != null);

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Sticky header: NEW HOOK title + Cancel always reachable.
                Row(
                  children: [
                    const Text(
                      'NEW HOOK',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: onCancelCreate,
                      style: TextButton.styleFrom(
                          foregroundColor: AppTheme.textMuted),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Scrollable middle: all form fields + the code editor
                // live inside SingleChildScrollView so the right pane
                // can scroll when the picker is open or the editor
                // grows.
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Kind',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        _KindSelector(
                          kind: newHookKind,
                          onChanged: onPickNewKind,
                        ),
                        if (newHookKind == _HookKind.replacement) ...[
                          const SizedBox(height: 10),
                          const Text(
                            'Target function',
                            style: TextStyle(
                                color: AppTheme.textMuted, fontSize: 11),
                          ),
                          const SizedBox(height: 4),
                          _SymbolPicker(
                            symbols: symbolNames,
                            value: newHookTargetSymbol,
                            onChanged: onPickNewTargetSymbol,
                          ),
                        ],
                        const SizedBox(height: 10),
                        const Text(
                          'Name',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        TextField(
                          controller: newHookNameController,
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontSize: 12),
                          decoration: InputDecoration(
                            hintText: 'My custom hook',
                            hintStyle: const TextStyle(
                                color: AppTheme.textMuted, fontSize: 12),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(4),
                                borderSide: const BorderSide(
                                    color: AppTheme.border)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Architecture',
                          style: TextStyle(
                              color: AppTheme.textMuted, fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCanvas,
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String?>(
                              value: newHookArchitecture,
                              isExpanded: true,
                              hint: const Text(
                                'Any',
                                style: TextStyle(
                                    color: AppTheme.textMuted,
                                    fontSize: 12),
                              ),
                              dropdownColor: AppTheme.bgPanel,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 12),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('Any'),
                                ),
                                for (final a in architectureChoices)
                                  DropdownMenuItem(
                                      value: a, child: Text(a)),
                              ],
                              onChanged: onPickNewArchitecture,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Code editor: fixed-height box so the
                        // surrounding SingleChildScrollView has a
                        // bounded layout. The multi-line TextField
                        // expands to fill this height and scrolls
                        // internally when the body overflows.
                        SizedBox(
                          height: 320,
                          child: _CodeField(
                            controller: codeController,
                            onChanged: onCodeChanged,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Sticky action row: Insert starter template + Generate
                // with LLM on the left, Create Hook on the right. All
                // always reachable regardless of scroll position.
                Row(
                  children: [
                    _StarterTemplateButton(
                      alreadyInserted: codeController.text
                          .trimLeft()
                          .startsWith(starterTemplatePrefix),
                      onInsert: onInsertStarter,
                    ),
                    const SizedBox(width: 8),
                    _GenerateWithLlmButton(onPressed: onGenerateWithLlm),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: canCreate ? onCreate : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        disabledBackgroundColor:
                            AppTheme.accent.withValues(alpha: 0.3),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Create Hook'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
}

class _ViewingHeader extends StatelessWidget {
  final Artifact artifact;
  final String label;
  final String arch;
  final int overrideUses;
  final bool isDefault;

  const _ViewingHeader({
    required this.artifact,
    required this.label,
    required this.arch,
    required this.overrideUses,
    required this.isDefault,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = StringBuffer();
    subtitle.write('Hook #${artifact.id}');
    if (artifact.name != null) {
      subtitle.write('  ·  ${artifact.name}');
    } else {
      subtitle.write('  ·  $label');
    }
    if (artifact.targetSymbolName != null) {
      subtitle.write('  ·  Replacement for ${artifact.targetSymbolName}');
    }
    if (overrideUses > 0) {
      subtitle.write(
          '  ·  $overrideUses active override${overrideUses == 1 ? '' : 's'}');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (arch.isNotEmpty)
              _Pill(text: arch, color: const Color(0xFF81C784)),
            const SizedBox(width: 4),
            if (isDefault)
              const _Pill(text: 'DEFAULT', color: Color(0xFFFFB74D))
            else
              const _Pill(text: 'USER', color: Color(0xFF4FC3F7)),
            if (artifact.targetSymbolName != null) ...[
              const SizedBox(width: 4),
              const _Pill(
                text: 'REPLACEMENT',
                color: Color(0xFFBA68C8),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          subtitle.toString(),
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _StarterTemplateButton extends StatelessWidget {
  final bool alreadyInserted;
  final VoidCallback onInsert;

  const _StarterTemplateButton({
    required this.alreadyInserted,
    required this.onInsert,
  });

  @override
  Widget build(BuildContext context) {
    final tooltip = alreadyInserted
        ? 'Starter template is already at the top of the editor.'
        : 'Insert a working example with comments explaining what '
            'each part does and where to edit.';
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: alreadyInserted ? null : onInsert,
        icon: const Icon(Icons.code, size: 14),
        label: const Text(
          'Insert starter template',
          style: TextStyle(fontSize: 12),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.textPrimary,
          disabledForegroundColor: AppTheme.textMuted,
          side: const BorderSide(color: AppTheme.border),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
    );
  }
}

/// "Generate with LLM" button. Disabled with a tooltip pointing the
/// user to System Configuration when the LLM module isn't installed.
class _GenerateWithLlmButton extends ConsumerWidget {
  final Future<void> Function() onPressed;
  const _GenerateWithLlmButton({required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(moduleEnabledProvider('MODULE_LLM_HOOKGEN'));
    final tooltip = enabled
        ? 'Describe the hook in plain English; the local LLM writes the '
            'code using RAG context from your project.'
        : 'Install the LLM module in Tools → System Configuration → '
            'Modules to enable hook generation.';
    return Tooltip(
      message: tooltip,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: const Icon(Icons.auto_awesome, size: 14),
        label: const Text(
          'Generate with LLM',
          style: TextStyle(fontSize: 12),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.textPrimary,
          disabledForegroundColor: AppTheme.textMuted,
          side: const BorderSide(color: AppTheme.border),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
    );
  }
}

class _KindSelector extends StatelessWidget {
  final _HookKind kind;
  final ValueChanged<_HookKind> onChanged;

  const _KindSelector({required this.kind, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: _KindRadio(
              label: 'Reusable',
              hint: 'Any symbol can pick this up',
              selected: kind == _HookKind.reusable,
              onTap: () => onChanged(_HookKind.reusable),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _KindRadio(
              label: 'Replacement',
              hint: 'Stands in for one specific function',
              selected: kind == _HookKind.replacement,
              onTap: () => onChanged(_HookKind.replacement),
            ),
          ),
        ],
      );
}

class _KindRadio extends StatelessWidget {
  final String label;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  const _KindRadio({
    required this.label,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.12)
                : AppTheme.bgCanvas,
            border: Border.all(
              color: selected ? AppTheme.accent : AppTheme.border,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 14,
                color: selected ? AppTheme.accent : AppTheme.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontSize: 12),
                    ),
                    Text(
                      hint,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _SymbolPicker extends StatefulWidget {
  final List<String> symbols;
  final String? value;
  final ValueChanged<String?> onChanged;

  const _SymbolPicker({
    required this.symbols,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_SymbolPicker> createState() => _SymbolPickerState();
}

class _SymbolPickerState extends State<_SymbolPicker> {
  final _filterController = TextEditingController();
  var _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Once a symbol is picked, collapse to a single read-only row
    // with a clear button — the filter + scrolling list go away so
    // the rest of the form (and the dialog scroll) has room.
    if (widget.value != null) {
      return Container(
        decoration: BoxDecoration(
          color: AppTheme.bgCanvas,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.check, size: 14, color: AppTheme.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.value!,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: () => widget.onChanged(null),
                icon: const Icon(Icons.close, size: 14),
                color: AppTheme.textMuted,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minHeight: 24, minWidth: 24),
                tooltip: 'Clear and pick a different symbol',
              ),
            ],
          ),
        ),
      );
    }
    final filtered = _filter.isEmpty
        ? widget.symbols
        : widget.symbols
            .where((s) => s.toLowerCase().contains(_filter.toLowerCase()))
            .toList();
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgCanvas,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: TextField(
              controller: _filterController,
              onChanged: (v) => setState(() => _filter = v),
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 11),
              decoration: InputDecoration(
                hintText: 'Filter symbols…',
                hintStyle: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 11),
                prefixIcon: const Icon(Icons.search,
                    size: 14, color: AppTheme.textMuted),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 6),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(3),
                    borderSide:
                        const BorderSide(color: AppTheme.border)),
              ),
            ),
          ),
          SizedBox(
            height: 140,
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'No matching symbols.',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final sym = filtered[i];
                      return InkWell(
                        onTap: () => widget.onChanged(sym),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          child: Text(
                            sym,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Modal "running test…" indicator shown while the Hook Test Harness
/// spawns a fresh Renode and runs the hook under test. Dismissed
/// programmatically when the harness call completes.
class _TestProgressDialog extends StatelessWidget {
  const _TestProgressDialog();

  @override
  Widget build(BuildContext context) => const Dialog(
        backgroundColor: AppTheme.bgPanel,
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text(
                'Running hook in a fresh Renode machine…',
                style: TextStyle(
                    color: AppTheme.textPrimary, fontSize: 12),
              ),
            ],
          ),
        ),
      );
}

class _CodeField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _CodeField({
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppTheme.bgCanvas,
          border: Border.all(color: AppTheme.border),
        ),
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.4,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(12),
            isCollapsed: true,
          ),
        ),
      );
}
