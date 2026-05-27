import '../../data/models/emulator.dart';
import '../../data/repositories/emulator_repository.dart';
import '../exceptions/orchestrator_exceptions.dart';

/// Handles emulator creation, loading, and saving workflows.
///
/// This workflow wraps EmulatorRepository (which handles file I/O) and adds:
/// - Dirty state tracking (hasUnsavedChanges)
/// - Emulator lifecycle events (created, loaded, saved, closed)
/// - Validation logic (unsaved changes check)
/// - Integration with orchestrator event system
class EmulatorWorkflow {
  final EmulatorRepository repository;
  final void Function(Emulator?) onEmulatorChanged;

  var _hasUnsavedChanges = false;

  EmulatorWorkflow({
    required this.repository,
    required this.onEmulatorChanged,
  });

  /// Create a new emulator (in-memory, not saved).
  ///
  /// The emulator is marked as dirty until saved.
  Future<Emulator> createEmulator({
    required String name,
    String? elfFilePath,
    String? baseImagePath,
  }) async {
    try {
      final emulator = repository.createEmulator(
        name: name,
        elfFilePath: elfFilePath,
        baseImagePath: baseImagePath,
      );

      _hasUnsavedChanges = true;
      onEmulatorChanged(emulator);

      return emulator;
    } catch (e) {
      throw EmulatorException('Failed to create emulator: $e');
    }
  }

  /// Load an existing emulator from file.
  ///
  /// Also adds the emulator to recent emulators list.
  Future<Emulator> loadEmulator(String emulatorPath) async {
    try {
      final emulator = await repository.loadEmulator(emulatorPath);
      await repository.addToRecentEmulators(emulatorPath, emulator.name);

      _hasUnsavedChanges = false;
      onEmulatorChanged(emulator);

      return emulator;
    } catch (e) {
      throw EmulatorException('Failed to load emulator: $e');
    }
  }

  /// Save the current emulator to disk.
  ///
  /// If no savePath is provided, uses the emulator's existing emulatorPath.
  /// Adds the emulator to recent emulators list after successful save.
  Future<void> saveEmulator(Emulator emulator, {String? savePath}) async {
    try {
      final path = savePath ?? emulator.emulatorPath;

      if (path == null) {
        throw EmulatorException('No save path provided and emulator has no existing path');
      }

      await repository.saveEmulator(emulator, path);
      await repository.addToRecentEmulators(path, emulator.name);

      _hasUnsavedChanges = false;

      // Update emulator with the save path if it changed
      final updatedEmulator = emulator.copyWith(emulatorPath: path);
      onEmulatorChanged(updatedEmulator);
    } catch (e) {
      throw EmulatorException('Failed to save emulator: $e');
    }
  }

  /// Close the current emulator.
  ///
  /// If [checkUnsaved] is true and there are unsaved changes,
  /// throws [UnsavedChangesException]. The UI should prompt the user
  /// for confirmation before proceeding.
  Future<void> closeEmulator({bool checkUnsaved = true}) async {
    if (checkUnsaved && _hasUnsavedChanges) {
      throw UnsavedChangesException('Emulator has unsaved changes');
    }

    onEmulatorChanged(null);
    _hasUnsavedChanges = false;
  }

  /// Mark the emulator as having unsaved changes.
  void markDirty() {
    _hasUnsavedChanges = true;
  }

  /// Check if the emulator has unsaved changes.
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  /// Clean up resources
  void dispose() {
    // No cleanup needed currently
  }
}
