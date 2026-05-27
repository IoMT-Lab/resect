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
              ],
            ),
          ),
          if (c.installable)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: () => _runInstall(c),
                child: const Text('Install'),
              ),
            ),
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
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallProgressDialog(component: c),
    );
    // Re-detect after an install attempt.
    ref.invalidate(componentStatusProvider(c.id));
  }
}

/// Streams a component's [Component.install] output into a scrolling log.
class _InstallProgressDialog extends StatefulWidget {
  const _InstallProgressDialog({required this.component});
  final Component component;

  @override
  State<_InstallProgressDialog> createState() => _InstallProgressDialogState();
}

class _InstallProgressDialogState extends State<_InstallProgressDialog> {
  final List<String> _lines = [];
  StreamSubscription<String>? _sub;
  var _done = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.component.install().listen(
      (line) => setState(() => _lines.add(line)),
      onError: (Object e) => setState(() {
        _failed = true;
        _done = true;
        _lines.add('ERROR: $e');
      }),
      onDone: () => setState(() => _done = true),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
      backgroundColor: AppTheme.bgPanel,
      title: Text('Install — ${widget.component.title}'),
      content: SizedBox(
        width: 560,
        height: 320,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectionArea(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (_, i) => Text(
                _lines[i],
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: _failed && i == _lines.length - 1
                      ? Colors.red.shade300
                      : Colors.greenAccent,
                ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _done ? () => Navigator.of(context).pop() : null,
          child: Text(_done ? 'Close' : 'Working…'),
        ),
      ],
    );
}
