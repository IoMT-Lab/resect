import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../database/artifact_database.dart';
import '../models/firmware_record.dart';

/// Service for managing the local artifact library.
///
/// The artifact library indexes firmware images by their SHA-256 ELF hash
/// and stores per-symbol records. This enables lookup of previously seen
/// firmware and will eventually store Renode hooks and other artifacts.
class ArtifactLibraryService {
  final ArtifactDatabase _db;

  ArtifactLibraryService(this._db);

  /// Renode hook code that sets register 0 to 0 and returns to caller.
  static const String return0HookCode = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(0, 64))
cpu.PC = cpu.LR
''';

  /// Renode hook code that sets register 0 to 1 and returns to caller.
  static const String return1HookCode = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(1, 64))
cpu.PC = cpu.LR
''';

  /// Compute SHA-256 hash of an ELF file.
  ///
  /// Returns the hex-encoded hash string used as the database primary key.
  Future<String> hashElfFile(String elfFilePath) async {
    final file = File(elfFilePath);
    if (!await file.exists()) {
      throw ArtifactLibraryException('ELF file not found: $elfFilePath');
    }

    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Look up a firmware image by its ELF hash.
  ///
  /// Returns a [FirmwareRecord] with symbol names if found, null otherwise.
  Future<FirmwareRecord?> lookupFirmware(String elfHash) async {
    final firmware = await _db.getFirmwareByHash(elfHash);
    if (firmware == null) return null;

    final symbols = await _db.getSymbolsForFirmware(elfHash);
    return FirmwareRecord(
      elfHash: firmware.elfHash,
      fileName: firmware.fileName,
      createdAt: firmware.createdAt,
      symbolNames: symbols.map((s) => s.symbolName).toList(),
    );
  }

  /// Register a new firmware image with its symbols and default hooks.
  ///
  /// Creates the firmware record, all symbol records, and default hooks
  /// in a single atomic transaction.
  Future<FirmwareRecord> registerFirmware({
    required String elfHash,
    required String fileName,
    required List<String> symbolNames,
  }) async {
    stderr.writeln('Registering firmware $elfHash with ${symbolNames.length} symbols...');

    await _db.registerFirmware(
      elfHash: elfHash,
      fileName: fileName,
      symbolNames: symbolNames,
      return0HookCode: return0HookCode,
      return1HookCode: return1HookCode,
    );

    // Verify registration
    final symbols = await _db.getSymbolsForFirmware(elfHash);
    stderr.writeln('Verified: ${symbols.length} symbols in DB');
    if (symbols.isNotEmpty) {
      final sampleHooks = await _db.getArtifactsForSymbol(symbols.first.id);
      stderr.writeln('Verified: ${sampleHooks.length} hooks for first symbol '
          '(${symbols.first.symbolName})');
    }

    return FirmwareRecord(
      elfHash: elfHash,
      fileName: fileName,
      createdAt: DateTime.now(),
      symbolNames: symbolNames,
    );
  }

  /// Process an ELF file: hash it, check the library, register if new.
  ///
  /// This is the main entry point for the artifact library workflow.
  /// Given an ELF file path and its symbol names (from the call graph),
  /// it will:
  /// 1. Hash the ELF file
  /// 2. Look up the hash in the local library
  /// 3. If not found, register the firmware and its symbols
  /// 4. Return the firmware record
  Future<FirmwareRecord> processElfFile({
    required String elfFilePath,
    required List<String> symbolNames,
  }) async {
    final elfHash = await hashElfFile(elfFilePath);
    final fileName = p.basename(elfFilePath);

    // Check local library
    final existing = await lookupFirmware(elfHash);
    if (existing != null) {
      // Ensure default hooks exist (may be missing if a previous run
      // registered firmware but crashed before creating hooks)
      await _ensureDefaultHooks(elfHash);
      return existing;
    }

    // Check remote library (stub - always returns null for now)
    await checkRemoteLibrary(elfHash);

    // Register new firmware
    return registerFirmware(
      elfHash: elfHash,
      fileName: fileName,
      symbolNames: symbolNames,
    );
  }

  /// Ensure every symbol for this firmware has default hooks.
  ///
  /// This handles the case where firmware was registered but hook creation
  /// was interrupted, or where the firmware existed from a previous run.
  Future<void> _ensureDefaultHooks(String elfHash) async {
    final symbols = await _db.getSymbolsForFirmware(elfHash);
    for (final symbol in symbols) {
      final existing = await _db.getArtifactsForSymbol(symbol.id);
      if (existing.isEmpty) {
        await _db.addArtifact(
          symbolId: symbol.id,
          artifactType: 'renode_hook',
          artifactData: return0HookCode,
        );
        await _db.addArtifact(
          symbolId: symbol.id,
          artifactType: 'renode_hook',
          artifactData: return1HookCode,
        );
      }
    }
  }

  /// Check the remote community artifact library for this firmware.
  ///
  /// Stub implementation - always returns null ("not available").
  /// This will be implemented when the remote library API is available.
  Future<FirmwareRecord?> checkRemoteLibrary(String elfHash) async {
    // TODO: Implement remote library check when API is available
    return null;
  }
}

/// Exception thrown when artifact library operations fail.
class ArtifactLibraryException implements Exception {
  final String message;

  ArtifactLibraryException(this.message);

  @override
  String toString() => 'ArtifactLibraryException: $message';
}
