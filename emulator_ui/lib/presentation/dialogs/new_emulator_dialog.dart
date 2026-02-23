import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

/// Dialog for creating a new emulator.
///
/// Allows users to enter an emulator name and optionally select firmware files.
/// Returns a map with emulator details if created, null if cancelled.
class NewEmulatorDialog extends StatefulWidget {
  const NewEmulatorDialog({super.key});

  /// Show the dialog and return emulator details or null
  static Future<Map<String, String?>?> show(BuildContext context) {
    return showDialog<Map<String, String?>>(
      context: context,
      builder: (context) => const NewEmulatorDialog(),
    );
  }

  @override
  State<NewEmulatorDialog> createState() => _NewEmulatorDialogState();
}

class _NewEmulatorDialogState extends State<NewEmulatorDialog> {
  final _nameController = TextEditingController();
  String? _elfFilePath;
  String? _baseImagePath;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _nameController.text = 'Untitled Emulator';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Emulator'),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Emulator name field
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Emulator Name',
                  hintText: 'Enter emulator name',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Emulator name is required';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _handleCreate(),
              ),

              const SizedBox(height: 24),

              // Optional firmware selection
              const Text(
                'Optional: Select firmware files now or add them later',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),

              const SizedBox(height: 12),

              // ELF file selection
              _buildFileSelector(
                label: 'Firmware ELF File',
                path: _elfFilePath,
                icon: Icons.memory,
                onSelect: () => _selectElfFile(),
                onClear: () => setState(() => _elfFilePath = null),
              ),

              const SizedBox(height: 8),

              // Base image selection
              _buildFileSelector(
                label: 'Platform File (.repl)',
                path: _baseImagePath,
                icon: Icons.developer_board,
                onSelect: () => _selectBaseImage(),
                onClear: () => setState(() => _baseImagePath = null),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _handleCreate,
          child: const Text('Create'),
        ),
      ],
    );
  }

  Widget _buildFileSelector({
    required String label,
    required String? path,
    required IconData icon,
    required VoidCallback onSelect,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                if (path != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _getFileName(path),
                    style: const TextStyle(fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (path != null)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: onClear,
              tooltip: 'Clear',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onSelect,
            icon: Icon(path == null ? Icons.folder_open : Icons.edit, size: 14),
            label: Text(path == null ? 'Select' : 'Change', style: const TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectElfFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select Firmware ELF File',
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _elfFilePath = result.files.single.path!;
      });
    }
  }

  Future<void> _selectBaseImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['repl'],
      dialogTitle: 'Select Platform File',
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _baseImagePath = result.files.single.path!;
      });
    }
  }

  void _handleCreate() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.of(context).pop({
      'name': _nameController.text.trim(),
      'elfFilePath': _elfFilePath,
      'baseImagePath': _baseImagePath,
    });
  }

  String _getFileName(String path) {
    return path.split('/').last;
  }
}
