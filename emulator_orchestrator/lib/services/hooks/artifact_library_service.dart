import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:resect_callgraph/resect_callgraph.dart' show Machine, getMachineForElf;

import '../../data/database/artifact_database.dart';
import '../../data/models/firmware_record.dart';
import '../analysis/call_graph_guard.dart';
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

  /// Compute SHA-256 hash of an ELF file. Same digest that stamps call
  /// graphs ([sha256OfFile]), so firmware records and graph stamps
  /// compare directly.
  Future<String> hashElfFile(String elfFilePath) async {
    try {
      return await sha256OfFile(elfFilePath);
    } on FileSystemException {
      throw ArtifactLibraryException('ELF file not found: $elfFilePath');
    }
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
    await ensureIntrinsicScores();
    await migrateLegacyHookBodies();

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

  /// Back-fill `intrinsic_score` for any artifact row where it's
  /// currently NULL — the "not yet scored" state. Idempotent: rows
  /// with a previously-set score (any non-null value) are left alone,
  /// so Stage 3's harness-derived intrinsic updates won't get
  /// clobbered on the next boot.
  ///
  /// The magnitudes follow the radiant-inventing-dream plan §2.1:
  ///
  /// - Catalog `return 0` / `return 1` / legacy returns → **0.0**
  ///   (no-op; only intrinsic value is "doesn't error").
  /// - Catalog increment / counter → **0.1** (stateful, mildly useful
  ///   in general).
  /// - Catalog read / write templates → **0.2** (protocol-shaped; in
  ///   the right binding much more useful, but bare intrinsic is generic).
  /// - User-authored Reusable (`origin='user'`,
  ///   `targetSymbolName == null`) → **0.3**.
  /// - User-authored Replacement (`origin='user'`,
  ///   `targetSymbolName != null`) → **0.5** (floor — the per-project
  ///   [HookBinding] fidelity at 1.0 is what should actually win for
  ///   the symbol this Replacement was authored for).
  /// - Anything else (unknown default body, unknown origin) → **0.0**.
  Future<void> ensureIntrinsicScores() async {
    final all = await _db.getAllArtifacts();
    final unscored = all.where((a) => a.intrinsicScore == null).toList();
    if (unscored.isEmpty) return;

    final templateScores = _catalogIntrinsicScores();
    var updated = 0;
    for (final a in unscored) {
      final double score;
      if (a.origin == 'default') {
        score = templateScores[a.artifactData] ?? 0.0;
      } else if (a.origin == 'user') {
        score = a.targetSymbolName == null ? 0.3 : 0.5;
      } else {
        score = 0.0;
      }
      await _db.updateArtifactIntrinsicScore(id: a.id, intrinsicScore: score);
      updated++;
    }
    stderr.writeln('[ArtifactLibrary] ensureIntrinsicScores: '
        '$updated row${updated == 1 ? '' : 's'} back-filled');
  }

  /// Map canonical default-template bodies to their intrinsic score.
  /// Builds from the catalog so the mapping moves in lockstep with
  /// what `ensureDefaultTemplates` actually inserts. Bodies the
  /// `defaultCodes()` set knows but this map doesn't fall through to
  /// 0.0 (safe floor for an unrecognized but-shipped template).
  Map<String, double> _catalogIntrinsicScores() {
    final scores = <String, double>{};

    // 0.0 — bare-no-op return-N templates.
    for (final v in [0, 1]) {
      scores[_catalog.build('return', {'value': v}).code] = 0.0;
    }
    // Safety net: anything in `defaultCodes()` that hasn't been
    // classified above falls through to 0.0 here. The remaining
    // entries (read/write/increment) get their real score from the
    // explicit blocks below, which overwrite this floor.
    final knownBuilt = scores.keys.toSet();
    for (final body in _catalog.defaultCodes()) {
      if (knownBuilt.contains(body)) continue;
      scores[body] = 0.0;
    }

    // 0.1 — increment/counter templates.
    for (final v in [0, 1]) {
      scores[_catalog
          .build('increment', {'scope': '', 'defaultValue': v}).code] = 0.1;
    }

    // 0.2 — read / write templates (protocol-shaped).
    for (final v in [0, 1]) {
      scores[_catalog
          .build('read', {'scope': '', 'defaultValue': v}).code] = 0.2;
    }
    for (final v in [0, 1]) {
      scores[_catalog.build('write',
          {'scope': '', 'value': v, 'returnValue': 0}).code] = 0.2;
    }

    return scores;
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

  /// Rewrite any existing `renode_hook` artifact whose body still
  /// contains a raw `import <synthetic-module>` line. Pre-fix paths
  /// (notably the LLM fallback in `SynthesizerWorkflow`) could write
  /// un-inlined hook code straight into `artifactData`; deploying
  /// those rows blows up Renode with `ImportException: No module
  /// named ...`. Running `updateArtifactData` on each affected row
  /// re-enters the DB write boundary, which now substitutes imports.
  /// Idempotent: a second pass finds no matching rows.
  Future<void> migrateLegacyHookBodies() async {
    final legacy = RegExp(
      r'^\s*(?:import|from)\s+'
      '(set_return_value|variables|comms|i2c_local|i2c_remote|'
      r'uart_remote|pointer|stm32_glue)\b',
      multiLine: true,
    );
    final rows = await _db.getAllArtifacts();
    var rewritten = 0;
    for (final row in rows) {
      if (row.artifactType != 'renode_hook') continue;
      if (!legacy.hasMatch(row.artifactData)) continue;
      await _db.updateArtifactData(id: row.id, artifactData: row.artifactData);
      rewritten++;
    }
    if (rewritten > 0) {
      stderr.writeln(
          '[ArtifactLibrary] migrateLegacyHookBodies: $rewritten row(s) '
          'rewritten with inlined imports');
    }
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
    // Pre-A2 `RegisterValue.Create(N, 64)` legacy bodies route to
    // the catalog `return` body — the legacy templates were
    // removed from the seed set on 2026-06-17 because they
    // duplicated the catalog-built returns. Existing DBs carrying
    // the old bodies migrate on the next manual Reseed.
    if (canonicalBody == null && obsoleteBody.contains('Create(0,')) {
      canonicalBody = _catalog.build('return', {'value': 0}).code;
    }
    if (canonicalBody == null && obsoleteBody.contains('Create(1,')) {
      canonicalBody = _catalog.build('return', {'value': 1}).code;
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

  /// 8 canonical default template bodies: catalog returns +
  /// read/write/increment × value 0/1.
  ///
  /// Two pre-A2 `RegisterValue.Create(N, 64)` legacy return bodies
  /// were removed on 2026-06-17 because they duplicated the
  /// catalog-built returns; existing DBs migrate via the manual
  /// "Reseed defaults" button in the Hook Database dialog, which
  /// routes the old bodies to the catalog ids via
  /// `_matchCanonical`.
  List<String> _defaultTemplateCodes() => [
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
