import 'dart:io';
import 'package:callgraph/callgraph.dart' show Machine, getMachineForElf;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../database/artifact_database.dart';
import '../models/firmware_record.dart';
import 'hook_catalog.dart';

/// Service for managing the local artifact library.
///
/// The artifact library indexes firmware images by their SHA-256 ELF
/// hash and maintains a small global pool of default *template* hook
/// bodies (~10 rows under the v2 schema). User-authored hooks are
/// stored per (firmware, symbol). Per-symbol selection lives in
/// `Emulator.hookOverrides`, not in the DB.
class ArtifactLibraryService {
  final ArtifactDatabase _db;
  final HookCatalog _catalog;

  ArtifactLibraryService(this._db, {HookCatalog? catalog})
      : _catalog = catalog ?? HookCatalog.system();

  /// Compute SHA-256 hash of an ELF file.
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
  Future<FirmwareRecord?> lookupFirmware(String elfHash) async {
    final firmware = await _db.getFirmwareByHash(elfHash);
    if (firmware == null) return null;
    final symbols = await _db.getSymbolsForFirmware(elfHash);
    return FirmwareRecord(
      elfHash: firmware.elfHash,
      fileName: firmware.fileName,
      createdAt: firmware.createdAt,
      symbolNames: symbols.map((s) => s.symbolName).toList(),
      machine: firmware.machine == null
          ? null
          : Machine.fromValue(firmware.machine!),
    );
  }

  /// Register a firmware image and its symbol list. Does NOT insert any
  /// hooks — defaults live in the global template pool and are seeded
  /// independently via [ensureDefaultTemplates]. [machine] is the raw
  /// `e_machine` value from the ELF header.
  Future<FirmwareRecord> registerFirmware({
    required String elfHash,
    required String fileName,
    required List<String> symbolNames,
    Machine? machine,
  }) async {
    stderr.writeln('[ArtifactLibrary] registerFirmware: '
        '$elfHash (${symbolNames.length} symbols, '
        'machine=${machine?.name ?? '?'})');
    await _db.registerFirmware(
      elfHash: elfHash,
      fileName: fileName,
      symbolNames: symbolNames,
      machine: machine?.value,
    );
    return FirmwareRecord(
      elfHash: elfHash,
      fileName: fileName,
      createdAt: DateTime.now(),
      symbolNames: symbolNames,
      machine: machine,
    );
  }

  /// Hash the ELF, register if new, ensure templates exist, return the
  /// firmware record. Replaces the v1 N×10-row seed path.
  Future<FirmwareRecord> processElfFile({
    required String elfFilePath,
    required List<String> symbolNames,
  }) async {
    stderr.writeln('[ArtifactLibrary] processElfFile: $elfFilePath '
        '(${symbolNames.length} symbols)');
    final elfHash = await hashElfFile(elfFilePath);
    final fileName = p.basename(elfFilePath);

    await ensureDefaultTemplates();

    // Parse the machine field from the ELF header up front — cheap
    // (just the first ~20 bytes), and used both for fresh-register
    // and for backfilling pre-v5 rows.
    Machine? machine;
    try {
      machine = await getMachineForElf(elfFilePath);
    } catch (e) {
      stderr.writeln('[ArtifactLibrary] getMachineForElf failed: $e');
    }

    final existing = await lookupFirmware(elfHash);
    if (existing != null) {
      stderr.writeln(
          '[ArtifactLibrary] Existing firmware ${elfHash.substring(0, 8)}…');
      if (existing.machine == null && machine != null) {
        // Pre-v5 row with a freshly-resolved machine value — fill it
        // in so subsequent lookups don't have to re-parse.
        await _db.updateFirmwareMachine(
            elfHash: elfHash, machine: machine.value);
        return FirmwareRecord(
          elfHash: existing.elfHash,
          fileName: existing.fileName,
          createdAt: existing.createdAt,
          symbolNames: existing.symbolNames,
          machine: machine,
        );
      }
      return existing;
    }

    await checkRemoteLibrary(elfHash);
    return registerFirmware(
      elfHash: elfHash,
      fileName: fileName,
      symbolNames: symbolNames,
      machine: machine,
    );
  }

  /// Idempotently insert every default template body the catalog emits
  /// today, if not already present. Templates are global — independent
  /// of any specific firmware/symbol — so this runs once at app boot
  /// rather than per-firmware × per-symbol. Architecture is stamped
  /// ARM because every catalog builder today emits ARM ABI
  /// (`cpu.SetRegister(0, …) ; cpu.PC = cpu.LR`).
  Future<void> ensureDefaultTemplates() async {
    final expected = _defaultTemplateCodes();
    final present =
        (await _db.getTemplates()).map((a) => a.artifactData).toSet();
    var added = 0;
    for (final code in expected) {
      if (present.contains(code)) continue;
      await _db.addArtifact(
        artifactType: 'renode_hook',
        artifactData: code,
        origin: 'default',
        architecture: 'ARM',
      );
      added++;
    }
    stderr.writeln(
        '[ArtifactLibrary] ensureDefaultTemplates: $added inserted, '
        '${present.length + added} present total');
  }

  /// Replace any obsolete `origin='default'` template rows whose body
  /// no longer matches the catalog's current output. Returns
  /// `Map<int oldId, int newId>` so callers can remap any
  /// `hookOverrides` / `hookPreferences` that referenced the old ids.
  ///
  /// Templates are global, so this is firmware-independent — no
  /// elfHash arg.
  Future<Map<int, int>> reseedDefaults() async {
    final valid = _catalog.defaultCodes();
    return _db.transaction(() async {
      final remap = <int, int>{};
      final templates = await _db.getTemplates();
      // Anything default-origin that doesn't match the current catalog
      // output is obsolete.
      final obsolete =
          templates.where((a) => !valid.contains(a.artifactData)).toList();
      if (obsolete.isEmpty) return remap;

      // Ensure every canonical body exists; build a body→id map for
      // the survivors.
      final surviving = <String, int>{
        for (final a in templates)
          if (valid.contains(a.artifactData)) a.artifactData: a.id,
      };
      for (final body in valid) {
        if (surviving.containsKey(body)) continue;
        final newId = await _db.addArtifact(
          artifactType: 'renode_hook',
          artifactData: body,
          origin: 'default',
          architecture: 'ARM',
        );
        surviving[body] = newId;
      }

      // For each obsolete row, pick a replacement id. Strategy: match
      // the obsolete body to a canonical body via the catalog's label
      // (Stateful read (default N) → catalog's read N body, etc.).
      for (final old in obsolete) {
        final replacement = _matchCanonical(old.artifactData, surviving);
        if (replacement != null) {
          remap[old.id] = replacement;
        }
        await _db.deleteArtifact(old.id);
      }
      stderr.writeln('[ArtifactLibrary] reseedDefaults: '
          '${obsolete.length} obsolete templates replaced');
      return remap;
    });
  }

  /// Match an obsolete body to the canonical id for the same kind. Uses
  /// the same `_hookLabel`-style regexes that the metadata sidebar uses
  /// to identify hook kinds.
  int? _matchCanonical(String obsoleteBody, Map<String, int> survivors) {
    String? canonicalBody;
    final inc = RegExp(r"incrementVariable\('value',\s*(-?\d+)")
        .firstMatch(obsoleteBody);
    if (inc != null) {
      final n = int.parse(inc.group(1)!);
      canonicalBody = _catalog
          .build('increment', {'scope': '', 'defaultValue': n}).code;
    }
    final set = RegExp(r"setVariable\('value',\s*(-?\d+)\)")
        .firstMatch(obsoleteBody);
    if (canonicalBody == null && set != null) {
      final n = int.parse(set.group(1)!);
      canonicalBody = _catalog.build(
          'write', {'scope': '', 'value': n, 'returnValue': 0}).code;
    }
    final get = RegExp(r"getVariable\('value',\s*(-?\d+)\)")
        .firstMatch(obsoleteBody);
    if (canonicalBody == null && get != null) {
      final n = int.parse(get.group(1)!);
      canonicalBody =
          _catalog.build('read', {'scope': '', 'defaultValue': n}).code;
    }
    if (canonicalBody == null && obsoleteBody.contains('Create(0,')) {
      canonicalBody = _legacyReturn0HookCode;
    }
    if (canonicalBody == null && obsoleteBody.contains('Create(1,')) {
      canonicalBody = _legacyReturn1HookCode;
    }
    if (canonicalBody == null) {
      final ret = RegExp(r'setReturnValue\(cpu,\s*(-?\d+)\)')
          .firstMatch(obsoleteBody);
      if (ret != null) {
        final n = int.parse(ret.group(1)!);
        canonicalBody = _catalog.build('return', {'value': n}).code;
      }
    }
    return canonicalBody == null ? null : survivors[canonicalBody];
  }

  /// Pre-A2 hardcoded return0/return1 hook bodies — kept available
  /// alongside the catalog variants per earlier guidance.
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

  /// 10 canonical default template bodies: two legacy returns + two
  /// catalog returns + read/write/increment × value 0/1.
  List<String> _defaultTemplateCodes() => [
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
  /// Stub — always returns null.
  Future<FirmwareRecord?> checkRemoteLibrary(String elfHash) async {
    // TODO: Implement remote library check when API is available
    return null;
  }
}

class ArtifactLibraryException implements Exception {
  final String message;
  ArtifactLibraryException(this.message);
  @override
  String toString() => 'ArtifactLibraryException: $message';
}
