import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../database/artifact_database.dart';
import '../models/firmware_record.dart';
import 'hook_catalog.dart';

/// Service for managing the local artifact library.
///
/// The artifact library indexes firmware images by their SHA-256 ELF hash
/// and stores per-symbol records. Default hooks are generated through
/// [HookCatalog] (hooks-dart builders) rather than hand-written constants;
/// the DB still stores the resulting code strings verbatim.
class ArtifactLibraryService {
  final ArtifactDatabase _db;
  final HookCatalog _catalog;

  ArtifactLibraryService(this._db, {HookCatalog? catalog})
      : _catalog = catalog ?? HookCatalog.system();

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
      defaultHookCodes: _defaultHookCodes(),
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
    stderr.writeln('[ArtifactLibrary] processElfFile: $elfFilePath '
        '(${symbolNames.length} symbols)');
    final elfHash = await hashElfFile(elfFilePath);
    final fileName = p.basename(elfFilePath);

    // Check local library
    final existing = await lookupFirmware(elfHash);
    if (existing != null) {
      stderr.writeln(
          '[ArtifactLibrary] Existing firmware ${elfHash.substring(0, 8)}… — '
          'topping up default hooks if missing');
      await _ensureDefaultHooks(elfHash);
      return existing;
    }

    // Check remote library (stub - always returns null for now)
    await checkRemoteLibrary(elfHash);

    stderr.writeln(
        '[ArtifactLibrary] New firmware ${elfHash.substring(0, 8)}… — '
        'registering with ${_defaultHookCodes().length} default hooks');
    return registerFirmware(
      elfHash: elfHash,
      fileName: fileName,
      symbolNames: symbolNames,
    );
  }

  /// Ensure every symbol for this firmware has the full set of default
  /// hooks. Idempotent: only inserts codes that aren't already present
  /// (exact string match against existing `artifactData`). Handles both:
  /// - registration crashed before hooks were written (existing == empty),
  /// - firmware was registered under an older default set (e.g. only
  ///   return-0/return-1) and now needs the new stateful variants topped up.
  Future<void> _ensureDefaultHooks(String elfHash) async {
    await _db.transaction(() async {
      final symbols = await _db.getSymbolsForFirmware(elfHash);
      final expected = _defaultHookCodes();
      var added = 0;
      for (final symbol in symbols) {
        final existing = await _db.getArtifactsForSymbol(symbol.id);
        final present = existing.map((a) => a.artifactData).toSet();
        for (final code in expected) {
          if (present.contains(code)) continue;
          await _db.addArtifact(
            symbolId: symbol.id,
            artifactType: 'renode_hook',
            artifactData: code,
          );
          added++;
        }
      }
      stderr.writeln('[ArtifactLibrary] _ensureDefaultHooks: '
          '${symbols.length} symbols, $added new artifacts inserted');
    });
  }

  /// Pre-A2 hardcoded return0/return1 hook bodies. Kept available alongside
  /// the catalog-built variants so the FORCE OVERRIDE dropdown surfaces both
  /// the legacy direct-`RegisterValue.Create` form and the new
  /// `setReturnValue`-via-helper form — per the user's directive to keep
  /// the "old and new both available" workflow.
  static const _legacyReturn0HookCode = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(0, 64))
cpu.PC = cpu.LR
''';
  static const _legacyReturn1HookCode = '''
from Antmicro.Renode.Peripherals.CPU import RegisterValue
cpu.SetRegister(0, RegisterValue.Create(1, 64))
cpu.PC = cpu.LR
''';

  /// Default hook code bodies seeded for every symbol in a freshly-registered
  /// firmware. Seven entries: the two legacy return-0/return-1 bodies, then
  /// the five catalog-built variants from hooks-dart's `simple_hooks.dart`.
  /// The stateful builders take a `scope` arg but their Python bodies don't
  /// reference it — passing the empty string here is intentional, scope is
  /// supplied at apply time from the user's per-override scope field
  /// (plan C2).
  List<String> _defaultHookCodes() => [
        _legacyReturn0HookCode,
        _legacyReturn1HookCode,
        _catalog.build('return', {'value': 0}).code,
        _catalog.build('return', {'value': 1}).code,
        _catalog.build('read', {'scope': '', 'defaultValue': 0}).code,
        _catalog.build('read', {'scope': '', 'defaultValue': 1}).code,
        _catalog.build(
            'write', {'scope': '', 'value': 0, 'returnValue': 0}).code,
        _catalog.build(
            'write', {'scope': '', 'value': 1, 'returnValue': 0}).code,
        _catalog.build('increment', {'scope': '', 'defaultValue': 0}).code,
        _catalog.build('increment', {'scope': '', 'defaultValue': 1}).code,
      ];

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
