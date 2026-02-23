import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import '../../core/app_paths.dart';
import '../models/emulator.dart';
import '../models/recent_emulator.dart';

/// Repository for emulator persistence operations.
///
/// Handles saving/loading `.emu` files, managing recent emulators list,
/// and exporting emulators as .zip archives.
class EmulatorRepository {
  static const int maxRecentEmulators = 10;
  static const String recentEmulatorsFileName = 'recent_emulators.json';
  static const String emulatorFileExtension = '.emu';

  /// Save emulator to specified file path
  Future<void> saveEmulator(Emulator emulator, String filePath) async {
    try {
      final file = File(filePath);

      // Ensure parent directory exists
      await file.parent.create(recursive: true);

      // Convert emulator to JSON
      final json = emulator.copyWith(emulatorPath: filePath).toJson();
      final jsonString = const JsonEncoder.withIndent('  ').convert(json);

      // Write to file
      await file.writeAsString(jsonString);
    } catch (e) {
      throw EmulatorException('Failed to save emulator: $e');
    }
  }

  /// Load emulator from file path (supports both .emu and legacy .emproj)
  Future<Emulator> loadEmulator(String filePath) async {
    try {
      final file = File(filePath);

      if (!await file.exists()) {
        throw EmulatorException('Emulator file not found: $filePath');
      }

      // Read and parse JSON
      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      // Validate version
      final version = json['version'] as String?;
      if (version != '1.0') {
        throw EmulatorException(
            'Unsupported emulator file version: $version');
      }

      // Parse emulator
      final emulator = Emulator.fromJson(json);

      // Set emulator path
      return emulator.copyWith(emulatorPath: filePath);
    } on FormatException catch (e) {
      throw EmulatorException('Invalid emulator file format: $e');
    } catch (e) {
      throw EmulatorException('Failed to load emulator: $e');
    }
  }

  /// Create a new emulator (in-memory, not saved)
  Emulator createEmulator({
    required String name,
    String? elfFilePath,
    String? baseImagePath,
  }) {
    return Emulator.create(
      name: name,
      elfFilePath: elfFilePath,
      baseImagePath: baseImagePath,
    );
  }

  /// Export emulator and firmware files to .zip archive
  Future<void> exportEmulator(Emulator emulator, String zipPath) async {
    try {
      // Ensure emulator is saved
      if (emulator.emulatorPath == null) {
        throw EmulatorException('Emulator must be saved before exporting');
      }

      final archive = Archive();
      final emulatorName = p.basenameWithoutExtension(emulator.emulatorPath!);

      // Add emulator file with relative paths
      final exportedEmulator = _prepareEmulatorForExport(emulator, emulatorName);
      final emulatorJson =
          const JsonEncoder.withIndent('  ').convert(exportedEmulator.toJson());
      archive.addFile(ArchiveFile(
        '$emulatorName.emu',
        emulatorJson.length,
        emulatorJson.codeUnits,
      ));

      // Add firmware file if exists
      if (emulator.elfFilePath != null) {
        final elfFile = File(emulator.elfFilePath!);
        if (await elfFile.exists()) {
          final elfBytes = await elfFile.readAsBytes();
          final relativePath = 'firmware/${p.basename(emulator.elfFilePath!)}';
          archive.addFile(ArchiveFile(
            relativePath,
            elfBytes.length,
            elfBytes,
          ));
        }
      }

      // Add base image file if exists
      if (emulator.baseImagePath != null) {
        final baseImageFile = File(emulator.baseImagePath!);
        if (await baseImageFile.exists()) {
          final baseImageBytes = await baseImageFile.readAsBytes();
          final relativePath =
              'platform/${p.basename(emulator.baseImagePath!)}';
          archive.addFile(ArchiveFile(
            relativePath,
            baseImageBytes.length,
            baseImageBytes,
          ));
        }
      }

      // Add document files
      for (final doc in emulator.documents) {
        final docFile = File(
          p.join(AppPaths.documentsDir(emulator.id), doc.filename),
        );
        if (await docFile.exists()) {
          final docBytes = await docFile.readAsBytes();
          archive.addFile(ArchiveFile(
            'documents/${doc.filename}',
            docBytes.length,
            docBytes,
          ));
        }
      }

      // Add README
      final readme = _generateReadme(emulator);
      archive.addFile(ArchiveFile(
        'README.txt',
        readme.length,
        readme.codeUnits,
      ));

      // Write ZIP file
      final zipEncoder = ZipEncoder();
      final zipFile = File(zipPath);
      await zipFile.writeAsBytes(zipEncoder.encode(archive)!);
    } catch (e) {
      throw EmulatorException('Failed to export emulator: $e');
    }
  }

  /// Prepare emulator for export (convert to relative paths)
  Emulator _prepareEmulatorForExport(Emulator emulator, String emulatorName) {
    String? elfPath;
    String? baseImagePath;

    if (emulator.elfFilePath != null) {
      elfPath = './firmware/${p.basename(emulator.elfFilePath!)}';
    }

    if (emulator.baseImagePath != null) {
      baseImagePath = './platform/${p.basename(emulator.baseImagePath!)}';
    }

    return emulator.copyWith(
      elfFilePath: elfPath,
      baseImagePath: baseImagePath,
    );
  }

  /// Generate README.txt for exported archive
  String _generateReadme(Emulator emulator) {
    return '''
Emulator Export
================

Emulator Name: ${emulator.name}
Export Date: ${DateTime.now().toIso8601String()}
Created: ${emulator.createdAt.toIso8601String()}
Modified: ${emulator.modifiedAt.toIso8601String()}

Contents:
---------
- ${p.basename(emulator.emulatorPath!)}.emu - Emulator file
${emulator.elfFilePath != null ? '- firmware/${p.basename(emulator.elfFilePath!)} - Firmware ELF file\n' : ''}${emulator.baseImagePath != null ? '- platform/${p.basename(emulator.baseImagePath!)} - Platform description\n' : ''}${emulator.documents.isNotEmpty ? '- documents/ - ${emulator.documents.length} associated document(s)\n' : ''}
To use this emulator:
1. Extract the archive
2. Open the .emu file in Call Graph Viewer
3. If firmware paths don't match, you'll be prompted to locate them

Generated by Call Graph Viewer v0.1.0
''';
  }

  /// Export emulator as a standalone Renode .resc script.
  ///
  /// The generated script includes platform setup, firmware loading,
  /// hook definitions, and hook mappings — everything needed to run
  /// the emulation in standalone Renode.
  Future<void> exportResc(Emulator emulator, String outputPath) async {
    if (emulator.elfFilePath == null) {
      throw EmulatorException('Emulator has no ELF file path');
    }
    if (emulator.baseImagePath == null) {
      throw EmulatorException('Emulator has no platform description path');
    }
    if (emulator.hooks.isEmpty) {
      throw EmulatorException('Emulator has no hooks to export');
    }

    final buf = StringBuffer();

    buf.writeln('# Auto-generated Renode script');
    buf.writeln('# Emulator: ${emulator.name}');
    buf.writeln('# Generated: ${DateTime.now().toIso8601String()}');
    buf.writeln('# Hooks: ${emulator.hooks.length}');
    buf.writeln();

    // Platform setup
    buf.writeln('mach create');
    buf.writeln('machine LoadPlatformDescription @${emulator.baseImagePath}');
    buf.writeln('sysbus LoadELF @${emulator.elfFilePath}');
    buf.writeln('sysbus.cpu WfiAsNop True');
    buf.writeln('sysbus.cpu LogFunctionNames True True');
    buf.writeln();

    // Hook definitions
    buf.writeln('# Hook definitions');
    for (final entry in emulator.hooks.entries) {
      final varName = '${entry.key}_hook';
      buf.writeln('set $varName');
      buf.writeln('"""');
      buf.writeln(entry.value.trim());
      buf.writeln('"""');
      buf.writeln();
    }

    // Hook mappings
    buf.writeln('# Hook mappings');
    for (final symbol in emulator.hooks.keys) {
      buf.writeln('sysbus AddHookAtSymbol "$symbol" \$${symbol}_hook');
    }
    buf.writeln();

    buf.writeln('start');

    final file = File(outputPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(buf.toString());
  }

  // =========================================================================
  // DOCUMENT OPERATIONS
  // =========================================================================

  /// Copy a file into the emulator's documents directory.
  ///
  /// Returns a [DocumentEntry] for the copied file. If a file with the same
  /// name already exists, appends a numeric suffix (e.g., "guide (1).pdf").
  Future<DocumentEntry> addDocument(String emulatorId, String sourceFilePath) async {
    final docsDir = AppPaths.documentsDir(emulatorId);
    await Directory(docsDir).create(recursive: true);

    final sourceFile = File(sourceFilePath);
    if (!await sourceFile.exists()) {
      throw EmulatorException('Document file not found: $sourceFilePath');
    }

    final originalName = p.basename(sourceFilePath);
    final destFilename = await _uniqueFilename(docsDir, originalName);
    await sourceFile.copy(p.join(docsDir, destFilename));

    return DocumentEntry(
      filename: destFilename,
      displayName: originalName,
      addedAt: DateTime.now(),
    );
  }

  /// Remove a document file from the emulator's documents directory.
  Future<void> removeDocument(String emulatorId, String filename) async {
    final file = File(p.join(AppPaths.documentsDir(emulatorId), filename));
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Get the full path to a document file.
  String getDocumentPath(String emulatorId, String filename) {
    return p.join(AppPaths.documentsDir(emulatorId), filename);
  }

  /// Generate a unique filename by appending a numeric suffix if needed.
  Future<String> _uniqueFilename(String directory, String desiredName) async {
    if (!await File(p.join(directory, desiredName)).exists()) {
      return desiredName;
    }

    final baseName = p.basenameWithoutExtension(desiredName);
    final extension = p.extension(desiredName);
    var counter = 1;

    while (true) {
      final candidate = '$baseName ($counter)$extension';
      if (!await File(p.join(directory, candidate)).exists()) {
        return candidate;
      }
      counter++;
    }
  }

  /// Get list of recent emulators
  Future<List<RecentEmulator>> getRecentEmulators() async {
    try {
      final file = await _getRecentEmulatorsFile();

      if (!await file.exists()) {
        return [];
      }

      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      // Support both new and legacy key
      final recentList = (json['recent_emulators'] ?? json['recent_projects']) as List<dynamic>?;
      if (recentList == null) {
        return [];
      }

      return recentList
          .map((item) => RecentEmulator.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // If recent emulators file is corrupted, return empty list
      return [];
    }
  }

  /// Add emulator to recent emulators list
  Future<void> addToRecentEmulators(String emulatorPath, String emulatorName) async {
    try {
      final recentEmulators = await getRecentEmulators();

      // Remove if already exists
      recentEmulators.removeWhere((e) => e.path == emulatorPath);

      // Add to front
      recentEmulators.insert(
        0,
        RecentEmulator(
          path: emulatorPath,
          name: emulatorName,
          lastOpened: DateTime.now(),
        ),
      );

      // Keep only max entries
      if (recentEmulators.length > maxRecentEmulators) {
        recentEmulators.removeRange(maxRecentEmulators, recentEmulators.length);
      }

      // Save
      await _saveRecentEmulators(recentEmulators);
    } catch (e) {
      // Non-critical error, just log it
      print('Warning: Failed to update recent emulators: $e');
    }
  }

  /// Remove emulator from recent emulators list
  Future<void> removeFromRecentEmulators(String emulatorPath) async {
    try {
      final recentEmulators = await getRecentEmulators();
      recentEmulators.removeWhere((e) => e.path == emulatorPath);
      await _saveRecentEmulators(recentEmulators);
    } catch (e) {
      print('Warning: Failed to remove from recent emulators: $e');
    }
  }

  /// Clear all recent emulators
  Future<void> clearRecentEmulators() async {
    await _saveRecentEmulators([]);
  }

  /// Check if emulator file exists and is valid
  Future<bool> validateEmulatorFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return false;
      }

      // Try to parse it
      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      // Check version
      final version = json['version'] as String?;
      return version == '1.0';
    } catch (e) {
      return false;
    }
  }

  /// Get recent emulators file path
  Future<File> _getRecentEmulatorsFile() async {
    final filePath = p.join(AppPaths.configDir, recentEmulatorsFileName);
    return File(filePath);
  }

  /// Save recent emulators list
  Future<void> _saveRecentEmulators(List<RecentEmulator> emulators) async {
    final file = await _getRecentEmulatorsFile();
    await file.parent.create(recursive: true);

    final json = {
      'version': '1.0',
      'recent_emulators': emulators.map((e) => e.toJson()).toList(),
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(json);
    await file.writeAsString(jsonString);
  }
}

/// Exception thrown when emulator operations fail
class EmulatorException implements Exception {
  final String message;

  EmulatorException(this.message);

  @override
  String toString() => message;
}
