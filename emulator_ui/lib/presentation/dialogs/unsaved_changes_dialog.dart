import 'package:flutter/material.dart';

/// Action to take with unsaved changes
enum UnsavedChangesAction {
  save,      // Save changes before proceeding
  discard,   // Discard changes and proceed
  cancel,    // Cancel the operation
}

/// Dialog prompting user about unsaved changes.
///
/// Shows when closing/loading an emulator with unsaved modifications.
/// Returns the user's choice or null if dialog was dismissed.
class UnsavedChangesDialog extends StatelessWidget {
  final String emulatorName;

  const UnsavedChangesDialog({
    super.key,
    required this.emulatorName,
  });

  /// Show the dialog and return user's choice
  static Future<UnsavedChangesAction?> show(
    BuildContext context, {
    required String emulatorName,
  }) {
    return showDialog<UnsavedChangesAction>(
      context: context,
      barrierDismissible: false, // Require explicit choice
      builder: (context) => UnsavedChangesDialog(emulatorName: emulatorName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 8),
          Text('Unsaved Changes'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Do you want to save changes to "$emulatorName"?',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your changes will be lost if you don\'t save them.',
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChangesAction.discard),
          child: const Text('Don\'t Save'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChangesAction.cancel),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChangesAction.save),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
