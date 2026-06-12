import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/config_providers.dart';

/// System Configuration surface — a CMake-GUI-style editor for the build/
/// environment variables in `resect.config`, plus toggles for the optional
/// add-on modules. Doubles as the first-run setup wizard ([wizard] = true),
/// which pre-fills detected defaults and marks setup complete on finish.
class SystemConfigDialog extends ConsumerStatefulWidget {
  const SystemConfigDialog({super.key, this.wizard = false});

  final bool wizard;

  static Future<void> show(BuildContext context, {bool wizard = false}) => showDialog<void>(
      context: context,
      barrierDismissible: !wizard,
      builder: (_) => SystemConfigDialog(wizard: wizard),
    );

  @override
  ConsumerState<SystemConfigDialog> createState() => _SystemConfigDialogState();
}

class _SystemConfigDialogState extends ConsumerState<SystemConfigDialog> {
  final Map<String, TextEditingController> _controllers = {};
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(systemConfigProvider.notifier);
    // Seed controller text from the stored value, falling back to the detected
    // default on first run. NOTE: this must not mutate the provider here —
    // Riverpod forbids modifying providers during initState/build. The
    // controller values are pushed into the provider in [_save].
    for (final v in configVariables) {
      final existing = notifier.value(v.key);
      final initial =
          (widget.wizard && existing.isEmpty) ? notifier.detectFor(v) : existing;
      _controllers[v.key] = TextEditingController(text: initial);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
      backgroundColor: AppTheme.bgPanel,
      title: Text(widget.wizard ? 'Welcome — System Setup' : 'System Configuration'),
      content: SizedBox(
        width: 760,
        height: 560,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              if (widget.wizard)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Confirm the detected paths and choose optional modules. '
                    'You can reopen this anytime from Tools → System Configuration.',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                ),
              const TabBar(
                tabs: [
                  Tab(text: 'Environment'),
                  Tab(text: 'Modules'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildEnvironmentTab(),
                    _buildModulesTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _restoreDefaults,
          child: const Text('Restore Defaults'),
        ),
        if (!widget.wizard)
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(widget.wizard ? 'Finish Setup' : 'Save'),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    );

  // ---------------------------------------------------------------------------
  // Environment tab — the variable table

  Widget _buildEnvironmentTab() {
    final detected =
        configVariables.where((v) => v.tier == ConfigTier.detected).toList();
    final advanced =
        configVariables.where((v) => v.tier == ConfigTier.advanced).toList();
    final build =
        configVariables.where((v) => v.tier == ConfigTier.build).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Detected automatically — override only if a row shows red.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
        for (final v in detected) ...[
          _variableRow(v),
          const SizedBox(height: 6),
        ],
        _section('Advanced', advanced),
        _section(
          'Build & tooling',
          build,
          subtitle: 'Used by install.sh / run.sh — not the running session.',
        ),
      ],
    );
  }

  Widget _section(String title, List<ConfigVariable> vars, {String? subtitle}) {
    if (vars.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          for (final v in vars) ...[
            _variableRow(v),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _variableRow(ConfigVariable v) {
    final controller = _controllers[v.key]!;
    final validation = validateConfigValue(v, controller.text);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Tooltip(
            message: v.description,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(v.label,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              border: const OutlineInputBorder(),
              hintText: v.optional ? '(optional)' : null,
            ),
            onChanged: (text) {
              ref.read(systemConfigProvider.notifier).setValue(v.key, text);
              setState(() {});
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.auto_fix_high, size: 18),
          tooltip: 'Detect default',
          color: AppTheme.textMuted,
          onPressed: () {
            final detected = ref.read(systemConfigProvider.notifier).detectFor(v);
            controller.text = detected;
            ref.read(systemConfigProvider.notifier).setValue(v.key, detected);
            setState(() {});
          },
        ),
        SizedBox(
          width: 150,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                Icon(
                  validation.ok ? Icons.check_circle : Icons.error,
                  size: 14,
                  color: validation.ok ? Colors.green : Colors.red.shade400,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    validation.message,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: validation.ok ? AppTheme.textMuted : Colors.red.shade400,
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

  // ---------------------------------------------------------------------------
  // Modules tab — optional component toggles

  Widget _buildModulesTab() {
    final components = ref.watch(componentRegistryProvider);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: components.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _moduleRow(components[i]),
    );
  }

  Widget _moduleRow(Component c) {
    final enabled = ref.watch(moduleEnabledProvider(c.configKey));
    final statusAsync = ref.watch(componentStatusProvider(c.id));

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCanvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 2),
                Text(c.description,
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 6),
                statusAsync.when(
                  data: (s) => Row(
                    children: [
                      Icon(s.available ? Icons.check_circle : Icons.info_outline,
                          size: 13,
                          color: s.available ? Colors.green : Colors.orange),
                      const SizedBox(width: 4),
                      Text(s.detail,
                          style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                    ],
                  ),
                  loading: () => const Text('Checking…',
                      style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                  error: (e, _) => Text('Detection error: $e',
                      style: TextStyle(fontSize: 10, color: Colors.red.shade400)),
                ),
                // For the LLM module: once Ollama is installed and at
                // least one inference model is registered, expose two
                // runtime affordances — pick the active model from
                // installed ones, and add another model without
                // re-running the whole install flow.
                if (c is LlmHookGenComponent &&
                    statusAsync.value?.available == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _LlmActiveModelRow(component: c),
                  ),
              ],
            ),
          ),
          if (c.installable && statusAsync.value?.available != true)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: () => _runInstall(c),
                child: const Text('Install'),
              ),
            ),
          // The toggle only makes sense once the component's prerequisites
          // are present — until then there's nothing to enable. Show Install
          // alone for missing/uninstalled modules; show the toggle alone for
          // built-in or already-installed ones.
          if (statusAsync.value?.available == true)
            Switch(
              value: enabled,
              onChanged: (b) {
                ref.read(systemConfigProvider.notifier).setBool(c.configKey, b);
                setState(() {});
              },
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions

  void _restoreDefaults() {
    final notifier = ref.read(systemConfigProvider.notifier);
    // Re-detect every field. Order matters: ENGINE_DIR precedes RENODE_BIN in
    // [configVariables], so the dependent default resolves against the fresh value.
    for (final v in configVariables) {
      final detected = notifier.detectFor(v);
      _controllers[v.key]!.text = detected;
      notifier.setValue(v.key, detected);
    }
    setState(() {});
  }

  Future<void> _save() async {
    final notifier = ref.read(systemConfigProvider.notifier);
    // Sync any controller text (incl. wizard-seeded defaults the user never
    // edited) into the provider before persisting.
    for (final v in configVariables) {
      notifier.setValue(v.key, _controllers[v.key]!.text);
    }
    setState(() => _saving = true);
    try {
      await notifier.save(markSetupDone: widget.wizard);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${ref.read(systemConfigProvider).configPath}')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save config: $e')),
        );
      }
    }
  }

  Future<void> _runInstall(Component c) async {
    // The LLM module needs an inference-model tag to pull. Ask once
    // before launching the install dialog and persist it so the
    // component's install() picks it up via EnvConfig.
    if (c is LlmHookGenComponent) {
      final ok = await _promptForLlmModelTag();
      if (!ok) return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallProgressDialog(component: c),
    );
    // Re-detect after an install attempt.
    ref.invalidate(componentStatusProvider(c.id));
  }

  /// Show the card-based Gemma 4 model picker before kicking off the
  /// LLM module install. Pre-selects whichever catalog entry matches
  /// the current `LLM_MODEL` value; falls back to the recommended
  /// entry; opens the Advanced disclosure if the current tag is not
  /// in the catalog. Persists the chosen tag to `LLM_MODEL` so
  /// `LlmHookGenComponent.install()` reads it via EnvConfig. Returns
  /// false if the user cancels.
  Future<bool> _promptForLlmModelTag() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => const _ModelPickerDialog(),
    );
    if (picked == null || picked.isEmpty) return false;
    final notifier = ref.read(systemConfigProvider.notifier)
      ..setValue('LLM_MODEL', picked);
    // Persist immediately so the component's EnvConfig.load() picks it up.
    await notifier.save();
    return true;
  }
}

/// Runtime affordances for the LLM Hook Generation module after it's
/// installed: an "Active" dropdown that switches `LLM_MODEL` between
/// any inference model the user has pulled, plus a "+ Add another"
/// button that runs the existing model-picker dialog in pull-only
/// mode (doesn't touch `LLM_MODEL`).
class _LlmActiveModelRow extends ConsumerWidget {
  const _LlmActiveModelRow({required this.component});
  final LlmHookGenComponent component;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modelsAsync = ref.watch(installedInferenceModelsProvider);
    final active = ref.watch(systemConfigProvider).values['LLM_MODEL'] ?? '';
    return modelsAsync.when(
      loading: () => const Text('Listing installed models…',
          style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
      error: (e, _) => Text('Could not list models: $e',
          style: TextStyle(fontSize: 10, color: Colors.red.shade400)),
      data: (models) {
        if (models.isEmpty) {
          return const Text('No inference models installed yet.',
              style: TextStyle(fontSize: 10, color: AppTheme.textMuted));
        }
        // If the configured tag isn't among installed ones (user
        // pulled a tag manually, then deleted it; or the system
        // shipped with a default tag that hasn't been pulled yet),
        // surface that rather than silently snapping to the first
        // installed model. The recovery affordance below lets them
        // pull the missing tag inline.
        final activeIsMissing =
            active.isNotEmpty && !models.contains(active);
        final dropdownItems = {...models, if (active.isNotEmpty) active}
            .toList()
          ..sort();
        return Row(
          children: [
            const Text('Active:',
                style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            const SizedBox(width: 6),
            DropdownButton<String>(
              value: dropdownItems.contains(active) ? active : null,
              isDense: true,
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 11),
              items: [
                for (final tag in dropdownItems)
                  DropdownMenuItem(
                    value: tag,
                    child: Text(tag,
                        style: TextStyle(
                          fontSize: 11,
                          color: models.contains(tag)
                              ? AppTheme.textPrimary
                              : Colors.orange,
                        )),
                  ),
              ],
              onChanged: (picked) async {
                if (picked == null) return;
                final notifier = ref.read(systemConfigProvider.notifier)
                  ..setValue('LLM_MODEL', picked);
                await notifier.save();
                // Re-detect so the status string reflects the new
                // active model.
                ref.invalidate(componentStatusProvider(component.id));
              },
            ),
            // When the active tag isn't on the local Ollama yet,
            // offer an inline "Install" button so the user doesn't
            // have to remember the exact tag and re-enter it via
            // "+ Add model".
            if (activeIsMissing) ...[
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _pullMissingActive(context, ref, active),
                child: const Text('Install',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ),
            ],
            const SizedBox(width: 12),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _pullAdditional(context, ref),
              child: const Text('+ Add model',
                  style: TextStyle(fontSize: 11)),
            ),
          ],
        );
      },
    );
  }

  /// Pull the configured `LLM_MODEL` value when it's absent from the
  /// local Ollama. Uses the same install-progress dialog as the
  /// "+ Add model" flow, with a title that names what's happening.
  /// `LLM_MODEL` isn't touched — the user already picked the tag;
  /// this just realises the pull.
  Future<void> _pullMissingActive(
      BuildContext context, WidgetRef ref, String tag) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallProgressDialog(
        component: component,
        titleOverride: 'Pulling missing active model — $tag',
        streamBuilder: () => component.pullAdditionalModel(tag),
      ),
    );
    ref.invalidate(installedInferenceModelsProvider);
    ref.invalidate(componentStatusProvider(component.id));
  }

  /// Run the same `_ModelPickerDialog` the install flow uses, then —
  /// when the user picks a tag — pull it via the component's
  /// pull-only entry point without touching `LLM_MODEL`. Active
  /// selection stays unchanged; the new model just becomes available
  /// in the dropdown for later selection.
  Future<void> _pullAdditional(BuildContext context, WidgetRef ref) async {
    // _ModelPickerDialog only returns the picked tag; persisting
    // `LLM_MODEL` is the caller's responsibility. We deliberately
    // skip that here so the user's active model stays put — they're
    // adding capacity, not switching.
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => const _ModelPickerDialog(),
    );
    if (picked == null || picked.isEmpty) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallProgressDialog(
        component: component,
        titleOverride: 'Pulling additional model — $picked',
        streamBuilder: () => component.pullAdditionalModel(picked),
      ),
    );
    // Refresh the dropdown to include the newly-installed tag.
    ref.invalidate(installedInferenceModelsProvider);
    ref.invalidate(componentStatusProvider(component.id));
  }
}

/// Card-based picker over [gemmaCatalog] with an Advanced disclosure
/// for custom tags. Returns the chosen Ollama tag (or null on cancel)
/// via Navigator.pop.
class _ModelPickerDialog extends ConsumerStatefulWidget {
  const _ModelPickerDialog();

  @override
  ConsumerState<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends ConsumerState<_ModelPickerDialog> {
  /// Selected catalog entry's tag, or null when "Advanced (custom)" is active.
  String? _selectedCatalogTag;

  /// Custom tag from the Advanced TextField. Used when [_selectedCatalogTag]
  /// is null.
  late final TextEditingController _customController;

  /// Whether the Advanced disclosure is open.
  var _advancedOpen = false;

  @override
  void initState() {
    super.initState();
    final current = ref.read(systemConfigProvider.notifier).value('LLM_MODEL');
    final inCatalog = gemmaCatalog.any((e) => e.tag == current);
    if (current.isEmpty) {
      _selectedCatalogTag =
          gemmaCatalog.firstWhere((e) => e.recommended).tag;
      _customController = TextEditingController();
    } else if (inCatalog) {
      _selectedCatalogTag = current;
      _customController = TextEditingController();
    } else {
      // The user has a tag set that isn't in the curated list — open
      // Advanced pre-filled with it so they don't lose it.
      _selectedCatalogTag = null;
      _advancedOpen = true;
      _customController = TextEditingController(text: current);
    }
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  String? _resolveSelection() {
    if (_selectedCatalogTag != null) return _selectedCatalogTag;
    final custom = _customController.text.trim();
    return custom.isEmpty ? null : custom;
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: AppTheme.bgPanel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  'Choose inference model',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'These models run locally — bigger means better hook code '
                  'but more RAM/VRAM. Tags from ollama.com/library/gemma4. '
                  'RAM rule-of-thumb: ~2× download size for unquantized '
                  'inference.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ),
              const Divider(height: 1, color: AppTheme.border),
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shrinkWrap: true,
                  children: [
                    for (final entry in gemmaCatalog)
                      _CatalogRow(
                        entry: entry,
                        selected: _selectedCatalogTag == entry.tag,
                        onTap: () => setState(() {
                          _selectedCatalogTag = entry.tag;
                        }),
                      ),
                    _AdvancedDisclosure(
                      expanded: _advancedOpen,
                      onToggle: () => setState(() {
                        _advancedOpen = !_advancedOpen;
                        if (_advancedOpen) {
                          _selectedCatalogTag = null;
                        }
                      }),
                      controller: _customController,
                      active: _selectedCatalogTag == null,
                      onTextFocus: () => setState(() {
                        _selectedCatalogTag = null;
                      }),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppTheme.border),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: () {
                        final tag = _resolveSelection();
                        if (tag != null) Navigator.of(context).pop(tag);
                      },
                      icon: const Icon(Icons.download, size: 14),
                      label: const Text('Pull'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accent,
                        foregroundColor: Colors.white,
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

/// One row in the Gemma 4 picker — radio + tag + size + summary + an
/// optional "RECOMMENDED" pill on the right.
class _CatalogRow extends StatelessWidget {
  final GemmaCatalogEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _CatalogRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? AppTheme.accent : AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          entry.tag,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          entry.downloadSize,
                          style: const TextStyle(
                              color: AppTheme.textMuted, fontSize: 12),
                        ),
                        const Spacer(),
                        if (entry.recommended) const _RecommendedPill(),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.summary,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                        height: 1.4,
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

class _RecommendedPill extends StatelessWidget {
  const _RecommendedPill();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppTheme.accent.withValues(alpha: 0.15),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: const Text(
          'RECOMMENDED',
          style: TextStyle(
            color: AppTheme.accent,
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
      );
}

/// Collapsible "Advanced: enter a custom Ollama tag" row. When
/// expanded, shows a TextField + a link-style "View all tags" hint.
/// Selecting this row deselects all catalog entries.
class _AdvancedDisclosure extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final TextEditingController controller;
  final bool active;
  final VoidCallback onTextFocus;

  const _AdvancedDisclosure({
    required this.expanded,
    required this.onToggle,
    required this.controller,
    required this.active,
    required this.onTextFocus,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Advanced: enter a custom Ollama tag',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 0, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    onTap: onTextFocus,
                    onChanged: (_) => onTextFocus(),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.bgCanvas,
                      hintText: 'e.g. gemma4:12b-mlx',
                      hintStyle: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: BorderSide(
                          color: active
                              ? AppTheme.accent
                              : AppTheme.border,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: BorderSide(
                          color: active
                              ? AppTheme.accent
                              : AppTheme.border,
                        ),
                      ),
                    ),
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'See ollama.com/library/gemma4 for all tags (incl. '
                    '-mlx and -cloud variants).',
                    style:
                        TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      );
}

/// Streams a component's [Component.install] output into a scrolling
/// log plus a single bottom progress bar.
///
/// Routing: events with `progressFraction` set update the bar in
/// place (no log spam); events with `message` set append to the log.
/// Cancel cancels the subscription, which propagates through the
/// async generators down to the HTTP download.
class _InstallProgressDialog extends StatefulWidget {
  const _InstallProgressDialog({
    required this.component,
    this.titleOverride,
    this.streamBuilder,
  });
  final Component component;

  /// Title to show instead of the default `"Install — <component>"`.
  /// Used when reusing this dialog for non-install flows (e.g.
  /// "Pull additional model — gemma4:12b").
  final String? titleOverride;

  /// Override for the event stream the dialog drives. Defaults to
  /// `component.install()` when omitted, so existing callers don't
  /// need to change. Pass a different stream (e.g.
  /// `LlmHookGenComponent.pullAdditionalModel(tag)`) to reuse the
  /// same progress UI for partial flows.
  final Stream<InstallEvent> Function()? streamBuilder;

  @override
  State<_InstallProgressDialog> createState() => _InstallProgressDialogState();
}

class _InstallProgressDialogState extends State<_InstallProgressDialog> {
  final List<String> _lines = [];
  final _logController = ScrollController();
  StreamSubscription<InstallEvent>? _sub;
  double? _progress;
  String? _progressLabel;
  var _done = false;
  var _failed = false;
  var _canceled = false;

  @override
  void initState() {
    super.initState();
    final stream =
        widget.streamBuilder?.call() ?? widget.component.install();
    _sub = stream.listen(
      _onEvent,
      onError: (Object e) => setState(() {
        _failed = true;
        _done = true;
        _progress = null;
        _progressLabel = null;
        _lines.add('ERROR: $e');
      }),
      onDone: () => setState(() {
        _done = true;
        _progress = null;
        _progressLabel = null;
      }),
    );
  }

  void _onEvent(InstallEvent ev) {
    setState(() {
      if (ev.progressFraction != null) {
        _progress = ev.progressFraction;
        _progressLabel = ev.progressLabel;
      }
      if (ev.message != null) {
        _lines.add(ev.message!);
        // Drop the progress bar when a phase transition log line
        // arrives — the next phase will re-arm it if needed.
        if (ev.progressFraction == null) {
          _progress = null;
          _progressLabel = null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logController.hasClients) {
            _logController.jumpTo(_logController.position.maxScrollExtent);
          }
        });
      }
    });
  }

  Future<void> _cancel() async {
    if (_done) return;
    setState(() {
      _canceled = true;
      _lines.add('Canceled by user.');
    });
    await _sub?.cancel();
    _sub = null;
    if (mounted) {
      setState(() {
        _done = true;
        _progress = null;
        _progressLabel = null;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _logController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppTheme.bgPanel,
        title: Text(widget.titleOverride ??
            'Install — ${widget.component.title}'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectionArea(
                    child: ListView.builder(
                      controller: _logController,
                      itemCount: _lines.length,
                      itemBuilder: (_, i) => Text(
                        _lines[i],
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: (_failed || _canceled) &&
                                  i == _lines.length - 1
                              ? Colors.red.shade300
                              : Colors.greenAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_progress != null) ...[
                const SizedBox(height: 10),
                if (_progressLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      _progressLabel!,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: AppTheme.bgCanvas,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (!_done)
            TextButton(
              onPressed: _cancel,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.textMuted,
              ),
              child: const Text('Cancel'),
            ),
          TextButton(
            onPressed: _done ? () => Navigator.of(context).pop() : null,
            child: Text(_done ? 'Close' : 'Working…'),
          ),
        ],
      );
}
