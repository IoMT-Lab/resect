import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart';
import 'package:resect_signatures/resect_signatures.dart';

import '../../config/env_config.dart';
import '../../data/database/artifact_database.dart';
import 'ghidra_installer.dart';

// Re-export the signature types so UI code can reference them
// through `signatures_service.dart` without taking a direct
// dependency on the `signatures` package.
export 'package:resect_signatures/resect_signatures.dart'
    show FunctionSignature, Parameter;

/// Phase update emitted during extraction. The dialog/library card
/// can show "Building signatures cache… (HAL_Init / 247)" while the
/// Ghidra job runs.
class SignaturesProgress {
  const SignaturesProgress(this.message, {this.done, this.total});
  final String message;
  final int? done;
  final int? total;
}

/// Per-project signature cache backed by the `signatures` table in
/// [ArtifactDatabase]. Three responsibilities:
///
/// 1. **Lookup** — `signatureFor(elfHash, symbolName)` is a fast,
///    cache-only read (zero subprocess cost). Returns null when the
///    cache is empty or the symbol wasn't in the ELF.
/// 2. **Population** — `extractFor(elfPath)` runs Ghidra headless
///    via `signatures-dart` and writes every function it found into
///    the DB. Long-running (30 s-2 min); call once per ELF.
/// 3. **Status** — `hasSignaturesFor(elfHash)` tells callers
///    whether the cache has been populated yet, so the UI can decide
///    between "use it" and "kick off extraction".
///
/// Gated on `MODULE_GHIDRA` being enabled in `resect.config` — when
/// the module is off, all methods short-circuit (lookups return
/// null, extraction is a no-op). The caller doesn't need to check
/// the toggle separately; just call and handle null.
class SignaturesService {
  SignaturesService({required this.db, GhidraInstaller? ghidraInstaller})
      : ghidraInstaller = ghidraInstaller ?? GhidraInstaller();

  final ArtifactDatabase db;

  /// Used at extraction time to resolve `JAVA_HOME` (the managed
  /// Temurin JRE under `~/.local/share/resect/jdk/`, falling back
  /// to system Java when present and recent enough). The Riverpod
  /// layer injects the shared singleton so we don't re-detect on
  /// every extraction call.
  final GhidraInstaller ghidraInstaller;

  /// True when the Ghidra module is installed and toggled on.
  /// Reads `MODULE_GHIDRA` from `resect.config` each call — cheap
  /// (file read of a few hundred bytes) and avoids stale state if
  /// the user toggles the module without restarting the app.
  bool get _enabled =>
      (EnvConfig.load().get('MODULE_GHIDRA') ?? '') == '1';

  /// Resolved Ghidra install dir from `GHIDRA_DIR`, or null if the
  /// config var isn't set (in which case extraction will throw with
  /// a clear message).
  String? get _ghidraDir {
    final v = (EnvConfig.load().get('GHIDRA_DIR') ?? '').trim();
    return v.isEmpty ? null : v;
  }

  /// Cache lookup. Cheap. Returns null when:
  /// - The Ghidra module is disabled
  /// - No signatures have been extracted for this ELF yet
  /// - The specific symbol wasn't in the ELF (e.g. external imports)
  Future<FunctionSignature?> signatureFor({
    required String elfHash,
    required String symbolName,
  }) async {
    if (!_enabled) return null;
    final row = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) & t.symbolName.equals(symbolName)))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      final json = jsonDecode(row.signatureJson) as Map<String, dynamic>;
      return FunctionSignature.fromJson(symbolName, json);
    } catch (e) {
      // Corrupt cache row — surface to stderr and treat as a cache
      // miss so the caller can re-extract on the next opportunity.
      // No logger dep here; this should be rare enough that
      // upgrading the diagnostic isn't worth a transitive package.
      stderr.writeln(
        'SignaturesService: corrupt cache row for $elfHash/$symbolName: $e',
      );
      return null;
    }
  }

  /// True if at least one signature is cached for this ELF. Used by
  /// the UI to decide whether to surface "Build signatures cache…"
  /// vs treat the cache as ready.
  ///
  /// **Don't use this as the "extraction is fully done" gate** — see
  /// [hasCompleteGhidraExtractionFor]. Once schema v8 added four new
  /// tables that `extractFor` populates, a stale v7-era signatures
  /// cache can return true here while those new tables are still
  /// empty. `hasCompleteGhidraExtractionFor` is the right predicate
  /// for "should I (re-)run extraction".
  Future<bool> hasSignaturesFor(String elfHash) async {
    if (!_enabled) return false;
    final row = await (db.selectOnly(db.signatures)
          ..addColumns([db.signatures.symbolName])
          ..where(db.signatures.elfHash.equals(elfHash))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// True iff a complete Ghidra extraction has been recorded under
  /// the current schema for [elfHash] — defined as: at least one
  /// row exists in `ghidra_decompilations`.
  ///
  /// Why this predicate and not [hasSignaturesFor]: schema v8 added
  /// four new tables (decompilations / data types / data symbols /
  /// memory map). The migration created the empty tables; only a
  /// re-extraction populates them. A user upgrading from v7 has a
  /// populated `signatures` cache *and* empty new tables — exactly
  /// the bug `_primeSignatureCache` was hitting when its gate was
  /// `hasSignaturesFor`. Picking `ghidra_decompilations` as the
  /// canary (rather than e.g. `ghidra_call_graphs`) means any
  /// future schema bump that adds yet another table can update
  /// this check to AND it in, and pre-v8 caches still fail it.
  Future<bool> hasCompleteGhidraExtractionFor(String elfHash) async {
    if (!_enabled) return false;
    final row = await (db.selectOnly(db.ghidraDecompilations)
          ..addColumns([db.ghidraDecompilations.elfHash])
          ..where(db.ghidraDecompilations.elfHash.equals(elfHash))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Run Ghidra against [elfPath], populate BOTH the signatures
  /// cache and the call-graph cache in one extraction pass. Emits
  /// progress events for the dialog/library card to display.
  ///
  /// Throws when the module is disabled (caller should check
  /// `_enabled` via `hasSignaturesFor` or by reading
  /// `MODULE_GHIDRA` directly).
  ///
  /// The two caches share the same `analyzeHeadless` invocation —
  /// auto-analysis runs once, then the Jython script walks both
  /// the function manager (for signatures) and the reference
  /// manager (for call edges) over the same in-memory program db.
  Stream<SignaturesProgress> extractFor(String elfPath) async* {
    if (!_enabled) {
      throw StateError(
        'Ghidra module is not enabled (MODULE_GHIDRA != "1"). '
        'Toggle it on in Tools → System Configuration → Modules.',
      );
    }
    final dir = _ghidraDir;
    if (dir == null) {
      throw StateError(
        'GHIDRA_DIR is not set in resect.config. Re-run the Ghidra '
        'module install to populate it.',
      );
    }
    yield const SignaturesProgress(
      'Computing ELF hash…',
    );
    final elfHash = await _hashFile(File(elfPath));
    yield const SignaturesProgress(
      'Running Ghidra headless analysis (30 s – 2 min)…',
    );
    final start = DateTime.now();
    // Prefer the managed Temurin JRE we installed alongside Ghidra
    // (~/.local/share/resect/jdk/jdk-*/). Falls back to system Java
    // if we never had to download one — both code paths produce a
    // JRE >= 21 because GhidraInstaller verifies that during
    // install / detect.
    final javaHome = await ghidraInstaller.resolveJavaHome();
    final info = await extractProgramInfo(
      elfPath: elfPath,
      ghidraDir: dir,
      javaHome: javaHome,
    );
    final elapsed = DateTime.now().difference(start);
    final decompCount = info.decompilation.values
        .where((d) => d.source != null && d.source!.isNotEmpty)
        .length;
    yield SignaturesProgress(
      'Ghidra produced ${info.signatures.length} signatures + '
      '${info.callGraph.length} call-graph nodes + '
      '$decompCount decompilations + '
      '${info.dataTypes.length} data types + '
      '${info.dataSymbols.length} data symbols + '
      '${info.memoryMap.length} memory sections in '
      '${elapsed.inSeconds}s. Caching…',
      total: info.signatures.length,
    );
    await _replaceCacheFor(elfHash, info);
    yield SignaturesProgress(
      'Cached ${info.signatures.length} signatures + '
      '${info.callGraph.length} call-graph nodes + '
      '$decompCount decompilations + '
      '${info.dataTypes.length} data types + '
      '${info.dataSymbols.length} data symbols.',
      done: info.signatures.length,
      total: info.signatures.length,
    );
  }

  /// Replace ALL Ghidra caches for [elfHash] with the contents of
  /// [info]. We delete-then-insert (rather than upsert) so entries
  /// for functions / types / symbols that were removed in a new
  /// ELF build don't linger as stale rows. All six tables get
  /// rewritten in one transaction so consumers never see a
  /// half-updated state where one table matches a new ELF but the
  /// others are still from the old one.
  Future<void> _replaceCacheFor(String elfHash, ProgramInfo info) async {
    await db.transaction(() async {
      // Signatures table — one row per (elf, symbol).
      await (db.delete(db.signatures)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      for (final entry in info.signatures.entries) {
        await db.into(db.signatures).insert(
              SignaturesCompanion.insert(
                elfHash: elfHash,
                symbolName: entry.key,
                signatureJson: jsonEncode(entry.value.toJson()),
              ),
            );
      }
      // Call-graph table — one row per ELF (entire graph as JSON).
      await (db.delete(db.ghidraCallGraphs)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      await db.into(db.ghidraCallGraphs).insert(
            GhidraCallGraphsCompanion.insert(
              elfHash: elfHash,
              payloadJson: jsonEncode({
                for (final entry in info.callGraph.entries)
                  entry.key: entry.value.toJson(),
              }),
            ),
          );

      // Decompilation — one row per (elf, function). Skip rows
      // with null/empty source — they're noise downstream.
      await (db.delete(db.ghidraDecompilations)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      for (final entry in info.decompilation.entries) {
        final src = entry.value.source;
        if (src == null || src.isEmpty) continue;
        await db.into(db.ghidraDecompilations).insert(
              GhidraDecompilationsCompanion.insert(
                elfHash: elfHash,
                functionName: entry.key,
                sourceText: src,
              ),
            );
      }
      // Data types — one row per (elf, type path).
      await (db.delete(db.ghidraDataTypes)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      for (final entry in info.dataTypes.entries) {
        await db.into(db.ghidraDataTypes).insert(
              GhidraDataTypesCompanion.insert(
                elfHash: elfHash,
                typeName: entry.key,
                definitionText: entry.value.definition,
              ),
            );
      }
      // Data symbols — one row per (elf, symbol).
      await (db.delete(db.ghidraDataSymbols)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      for (final entry in info.dataSymbols.entries) {
        await db.into(db.ghidraDataSymbols).insert(
              GhidraDataSymbolsCompanion.insert(
                elfHash: elfHash,
                symbolName: entry.key,
                address: entry.value.address,
                typeName: entry.value.type,
                size: entry.value.size,
              ),
            );
      }
      // Memory map — one row per ELF (entire list as JSON).
      await (db.delete(db.ghidraMemoryMap)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();
      await db.into(db.ghidraMemoryMap).insert(
            GhidraMemoryMapCompanion.insert(
              elfHash: elfHash,
              payloadJson:
                  jsonEncode([for (final m in info.memoryMap) m.toJson()]),
            ),
          );
    });
  }

  Future<String> _hashFile(File f) async =>
      sha256.convert(await f.readAsBytes()).toString();
}
