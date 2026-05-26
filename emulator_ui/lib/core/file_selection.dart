import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Thin abstraction over file open/save dialogs.
///
/// Every UI surface picks files through this interface rather than a
/// concrete plugin, so the implementation is swappable in one place. The
/// desktop implementation ([NativeFileSelector]) uses `file_selector`,
/// which drives GTK's native chooser directly through the GTK already
/// linked into the Flutter Linux app — no external binary (zenity/kdialog)
/// required. A future web build can supply an upload-based implementation
/// without touching call sites.
abstract class FileSelector {
  /// Show an open-file dialog. Returns the selected path, or null if the
  /// user cancelled. [extensions] filters by file extension (without the
  /// dot); null or empty means any file.
  Future<String?> openFile({
    String? dialogTitle,
    List<String>? extensions,
    String? initialDirectory,
  });

  /// Show a save-file dialog. Returns the chosen path, or null if cancelled.
  Future<String?> saveFile({
    String? dialogTitle,
    String? suggestedName,
    List<String>? extensions,
    String? initialDirectory,
  });
}

/// Desktop [FileSelector] backed by the `file_selector` plugin (GTK native).
class NativeFileSelector implements FileSelector {
  const NativeFileSelector();

  List<fs.XTypeGroup> _typeGroups(List<String>? extensions) {
    if (extensions == null || extensions.isEmpty) {
      return const <fs.XTypeGroup>[];
    }
    return [fs.XTypeGroup(label: 'files', extensions: extensions)];
  }

  @override
  Future<String?> openFile({
    String? dialogTitle,
    List<String>? extensions,
    String? initialDirectory,
  }) async {
    final file = await fs.openFile(
      acceptedTypeGroups: _typeGroups(extensions),
      confirmButtonText: dialogTitle,
      initialDirectory: initialDirectory,
    );
    return file?.path;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? suggestedName,
    List<String>? extensions,
    String? initialDirectory,
  }) async {
    final location = await fs.getSaveLocation(
      acceptedTypeGroups: _typeGroups(extensions),
      suggestedName: suggestedName,
      confirmButtonText: dialogTitle,
      initialDirectory: initialDirectory,
    );
    return location?.path;
  }
}

final fileSelectorProvider = Provider<FileSelector>(
  (ref) => const NativeFileSelector(),
);
