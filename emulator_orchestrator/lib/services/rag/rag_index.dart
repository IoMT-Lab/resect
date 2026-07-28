import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../data/database/artifact_database.dart';
import '../../data/models/call_graph.dart';
import '../../data/models/emulator.dart';
import '../../data/models/rag_index_status.dart';
import '../../data/models/symbol.dart' as cg;
import '../llm/llm_client.dart';
import 'rag_chunker.dart';

/// Per-project RAG store backing the LLM hook-generation prompt.
///
/// Layout on disk: `<project dir>/rag_index.db`, a tiny SQLite file
/// holding two tables — `chunks` (text + 768-dim float32 embedding) and
/// `sources` (per-source content fingerprint, used to flag the index as
/// stale when a doc/symbol/hook changes upstream).
///
/// Retrieval is plain top-K cosine in Dart over the in-memory rows;
/// SQLite is just a durable bag. At v1's scale (≲ 1000 chunks per
/// project, ~3 MB of embeddings), this is fast enough and saves us a
/// vector-index dependency.
///
/// Construction is lightweight; the actual DB is opened lazily on the
/// first call to keep the Library tab cold-start free of disk work.
class RagIndex {
  RagIndex({
    required this.projectDir,
    required this.client,
    this.artifactDb,
    RagChunker? chunker,
  }) : chunker = chunker ?? const RagChunker();

  /// Absolute path of the project directory; the DB lives directly inside
  /// (alongside `documents/` and the `.emu` file).
  final String projectDir;

  final LlmClient client;
  final RagChunker chunker;

  /// Optional handle on the shared artifact DB, used during
  /// [rebuildFor] to pull Ghidra-extracted decompilation / data
  /// types / data symbols / memory map into the RAG store when
  /// the Ghidra module is enabled and `elfHash` is provided.
  /// Null on Library tabs that don't carry the artifact-DB
  /// dependency yet — those just skip the Ghidra pass.
  final ArtifactDatabase? artifactDb;

  Database? _db;
  String get _dbPath => p.join(projectDir, 'rag_index.db');

  Database get _open {
    final existing = _db;
    if (existing != null) return existing;
    final dir = Directory(projectDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final db = sqlite3.open(_dbPath)
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('''
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_kind TEXT NOT NULL,
          source_id   TEXT NOT NULL,
          position    INTEGER NOT NULL,
          text        TEXT NOT NULL,
          embedding   BLOB NOT NULL,
          UNIQUE(source_kind, source_id, position)
        );
      ''')
      ..execute('''
        CREATE INDEX IF NOT EXISTS chunks_source
          ON chunks(source_kind, source_id);
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS sources(
          source_kind TEXT NOT NULL,
          source_id   TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          indexed_at  INTEGER NOT NULL,
          PRIMARY KEY(source_kind, source_id)
        );
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS meta(
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      ''');
    return _db = db;
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  /// Read a snapshot of the index state for the Library tab's RAG card.
  /// Cheap — counts rows + reads the meta `last_built` timestamp; safe
  /// to call on every UI tick.
  RagIndexStatus statusSnapshot(Emulator emulator) {
    final db = _open;
    final total = (db.select('SELECT COUNT(*) AS n FROM chunks').first['n']
            as int?) ??
        0;
    final byKind = <String, int>{
      for (final row
          in db.select('SELECT source_kind, COUNT(*) AS n '
              'FROM chunks GROUP BY source_kind'))
        row['source_kind'] as String: row['n'] as int,
    };
    final lastBuiltMs = _readMeta('last_built_ms');
    final lastBuiltAt = lastBuiltMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(int.parse(lastBuiltMs));
    final stale = _stalenessCount(emulator);
    return RagIndexStatus(
      lastBuiltAt: lastBuiltAt,
      chunkCount: total,
      chunkCountsByKind: byKind,
      staleSourceCount: stale,
      inProgressPhase: null,
    );
  }

  /// Full (re)build over all sources reachable from [emulator]:
  /// attached documents, the call graph's symbol cards, and the
  /// project's user-authored hooks (catalog hooks are global and not
  /// indexed per project).
  ///
  /// Emits a stream of (phase, count) update messages so the RAG card
  /// can show "Embedding docs (3/12)…" as it goes. The caller is
  /// expected to update [RagIndexStatus.inProgressPhase] from these.
  ///
  /// Cancellable via subscription cancel.
  Stream<RagRebuildEvent> rebuildFor(
    Emulator emulator, {
    Iterable<UserHookEntry> userHooks = const [],
    String? elfHash,
  }) async* {
    // Snapshot the inputs and clear stale rows for any source no longer
    // present (e.g., user removed a doc). The actual embedding work
    // happens in passes so progress can be reported per kind.
    final db = _open;
    final docDir = Directory(p.join(projectDir, 'documents'));

    final docs = emulator.documents
        .where((d) => File(p.join(docDir.path, d.filename)).existsSync())
        .toList();
    final graph = emulator.cachedCallGraph;
    final symbols = graph?.symbols.values.toList() ?? const <cg.Symbol>[];

    // Snapshot the Ghidra-derived inputs up front so we can compute
    // the total work + the liveKeys set for the prune sweep in one
    // place. Empty when the module is off, the DB handle wasn't
    // wired in, or no elfHash was provided.
    final ghidra = await _snapshotGhidraInputs(elfHash);

    final liveKeys = <(String, String)>{
      for (final d in docs) ('doc', d.filename),
      for (final s in symbols) ('symbol', s.name),
      for (final h in userHooks) ('hook', h.id),
      for (final r in ghidra.decompilations) ('decompilation', r.functionName),
      for (final r in ghidra.dataTypes) ('data_type', r.typeName),
      for (final id in ghidra.dataSymbolBatchIds) ('data_symbol', id),
      if (ghidra.hasMemoryMap) ('memory_section', _memorySectionSourceId),
    };
    _pruneAbsentSources(db, liveKeys);

    var done = 0;
    final total = docs.length +
        symbols.length +
        userHooks.length +
        ghidra.totalWorkUnits;
    yield RagRebuildEvent(phase: 'Starting…', done: 0, total: total);

    for (final doc in docs) {
      final fingerprint = await _fingerprintFile(
        File(p.join(docDir.path, doc.filename)),
      );
      if (_sourceUnchanged('doc', doc.filename, fingerprint)) {
        done++;
        yield RagRebuildEvent(
          phase: 'Skipping unchanged: ${doc.displayName}',
          done: done,
          total: total,
        );
        continue;
      }
      yield RagRebuildEvent(
        phase: 'Chunking ${doc.displayName}…',
        done: done,
        total: total,
      );
      try {
        final chunks = await chunker.chunkDocument(
          File(p.join(docDir.path, doc.filename)),
          sourceId: doc.filename,
        );
        await _embedAndStore(chunks);
        _writeSourceFingerprint('doc', doc.filename, fingerprint);
      } on Exception catch (e) {
        yield RagRebuildEvent(
          phase: 'Skipped ${doc.displayName}: $e',
          done: done,
          total: total,
        );
      }
      done++;
    }

    for (final sym in symbols) {
      final card = _renderSymbolCard(sym, graph);
      final fp = _hashString(card);
      if (_sourceUnchanged('symbol', sym.name, fp)) {
        done++;
        continue;
      }
      final chunks = chunker.chunkText(
        card,
        sourceKind: 'symbol',
        sourceId: sym.name,
      );
      await _embedAndStore(chunks);
      _writeSourceFingerprint('symbol', sym.name, fp);
      done++;
      if (done % 25 == 0) {
        yield RagRebuildEvent(
          phase: 'Embedding symbols ($done/$total)…',
          done: done,
          total: total,
        );
      }
    }

    for (final hook in userHooks) {
      final card = '## ${hook.displayName}\n\n${hook.body}';
      final fp = _hashString(card);
      if (_sourceUnchanged('hook', hook.id, fp)) {
        done++;
        continue;
      }
      final chunks = chunker.chunkText(
        card,
        sourceKind: 'hook',
        sourceId: hook.id,
      );
      await _embedAndStore(chunks);
      _writeSourceFingerprint('hook', hook.id, fp);
      done++;
    }

    if (ghidra.totalWorkUnits > 0) {
      yield RagRebuildEvent(
        phase: 'Indexing Ghidra-derived program facts…',
        done: done,
        total: total,
      );
      await for (final ev in _embedGhidraChunks(ghidra, done, total)) {
        done = ev.done;
        yield ev;
      }
    }

    _writeMeta('last_built_ms',
        DateTime.now().millisecondsSinceEpoch.toString());
    yield RagRebuildEvent(phase: 'Done.', done: total, total: total);
  }

  /// Snapshot of the per-ELF Ghidra rows the rebuild pass needs.
  /// Pulled in one go before chunking starts so we can pre-compute
  /// `liveKeys` (for the prune sweep) and `total` (for progress).
  /// Empty when `MODULE_GHIDRA` is off, no DB handle was wired in,
  /// or [elfHash] is null.
  Future<_GhidraRagInputs> _snapshotGhidraInputs(String? elfHash) async {
    final db = artifactDb;
    if (db == null || elfHash == null || elfHash.isEmpty) {
      return const _GhidraRagInputs(
        decompilations: [],
        dataTypes: [],
        dataSymbolBatchIds: [],
        dataSymbolBatchTexts: [],
        hasMemoryMap: false,
        memoryMapText: '',
      );
    }
    final decomps = await db.decompilationsFor(elfHash);
    final dtypes = await db.dataTypesFor(elfHash);
    final dsymbols = await db.dataSymbolsFor(elfHash);
    final mmJson = await db.memoryMapPayloadFor(elfHash);

    // Bundle data symbols into batches of 20. A chunk listing 20
    // globals reads as a coherent address-table snippet; 20 separate
    // single-line chunks just dilutes retrieval ranking.
    const batchSize = 20;
    final batchIds = <String>[];
    final batchTexts = <String>[];
    for (var i = 0; i < dsymbols.length; i += batchSize) {
      final batch =
          dsymbols.sublist(i, (i + batchSize).clamp(0, dsymbols.length));
      if (batch.isEmpty) continue;
      // Use the first symbol's name as the batch id so prune-sweeps
      // line up across rebuilds (deterministic for the same ELF).
      batchIds.add('batch_${batch.first.symbolName}');
      batchTexts.add(batch
          .map((s) =>
              '${s.symbolName} @ 0x${s.address.toRadixString(16)} '
              '(${s.typeName}, ${s.size} bytes)')
          .join('\n'));
    }

    var memoryMapText = '';
    if (mmJson != null && mmJson.isNotEmpty) {
      try {
        final list = jsonDecode(mmJson) as List;
        memoryMapText = list.map((raw) {
          final m = raw as Map<String, dynamic>;
          final start = (m['start'] as num).toInt();
          final end = (m['end'] as num).toInt();
          return '${m['name']}  '
              '0x${start.toRadixString(16)}-'
              '0x${end.toRadixString(16)}  '
              '[${m['permissions']}]';
        }).join('\n');
      } catch (_) {
        // Corrupt payload — surface as empty so the rebuild
        // doesn't crash; SignaturesService will overwrite it on
        // the next extraction.
        memoryMapText = '';
      }
    }

    return _GhidraRagInputs(
      decompilations: decomps,
      dataTypes: dtypes,
      dataSymbolBatchIds: batchIds,
      dataSymbolBatchTexts: batchTexts,
      hasMemoryMap: memoryMapText.isNotEmpty,
      memoryMapText: memoryMapText,
    );
  }

  /// Embed the four Ghidra-derived passes. Tracks staleness via the
  /// same `sources` fingerprint mechanism docs and symbols use, so
  /// re-running on an unchanged ELF skips embeddings cheaply.
  Stream<RagRebuildEvent> _embedGhidraChunks(
    _GhidraRagInputs ghidra,
    int startDone,
    int total,
  ) async* {
    var done = startDone;

    for (final entry in ghidra.decompilations) {
      final fp = _hashString(entry.sourceText);
      if (!_sourceUnchanged(
          'decompilation', entry.functionName, fp)) {
        final chunks = chunker.chunkText(
          entry.sourceText,
          sourceKind: 'decompilation',
          sourceId: entry.functionName,
        );
        await _embedAndStore(chunks);
        _writeSourceFingerprint('decompilation', entry.functionName, fp);
      }
      done++;
      if (done % 25 == 0) {
        yield RagRebuildEvent(
          phase: 'Embedding decompilations ($done/$total)…',
          done: done,
          total: total,
        );
      }
    }

    for (final entry in ghidra.dataTypes) {
      final fp = _hashString(entry.definitionText);
      if (!_sourceUnchanged('data_type', entry.typeName, fp)) {
        final chunks = chunker.chunkText(
          entry.definitionText,
          sourceKind: 'data_type',
          sourceId: entry.typeName,
        );
        await _embedAndStore(chunks);
        _writeSourceFingerprint('data_type', entry.typeName, fp);
      }
      done++;
    }

    for (var i = 0; i < ghidra.dataSymbolBatchIds.length; i++) {
      final id = ghidra.dataSymbolBatchIds[i];
      final text = ghidra.dataSymbolBatchTexts[i];
      final fp = _hashString(text);
      if (!_sourceUnchanged('data_symbol', id, fp)) {
        final chunks = chunker.chunkText(
          text,
          sourceKind: 'data_symbol',
          sourceId: id,
        );
        await _embedAndStore(chunks);
        _writeSourceFingerprint('data_symbol', id, fp);
      }
      done++;
    }

    if (ghidra.hasMemoryMap) {
      final fp = _hashString(ghidra.memoryMapText);
      if (!_sourceUnchanged(
          'memory_section', _memorySectionSourceId, fp)) {
        final chunks = chunker.chunkText(
          ghidra.memoryMapText,
          sourceKind: 'memory_section',
          sourceId: _memorySectionSourceId,
        );
        await _embedAndStore(chunks);
        _writeSourceFingerprint(
            'memory_section', _memorySectionSourceId, fp);
      }
      done++;
    }

    yield RagRebuildEvent(
      phase: 'Ghidra facts indexed.',
      done: done,
      total: total,
    );
  }

  /// Single canonical source-id for the memory-map chunk (there's
  /// one memory map per ELF; we don't shard it).
  static const _memorySectionSourceId = 'program_memory_map';

  /// Top-K nearest chunks to [queryText] by cosine similarity.
  ///
  /// Optionally restrict by [kinds] (e.g. `{'hook'}` for the few-shot
  /// catalog slice of the prompt) and exclude already-selected chunks
  /// via [exclude]. Returns an empty list when the index is empty.
  Future<List<RagHit>> retrieve(
    String queryText, {
    int topK = 10,
    Set<String>? kinds,
    Set<int> exclude = const {},
  }) async {
    final db = _open;
    final rows = kinds == null
        ? db.select('SELECT id, source_kind, source_id, text, embedding '
            'FROM chunks')
        : db.select(
            'SELECT id, source_kind, source_id, text, embedding '
            'FROM chunks WHERE source_kind IN (${List.filled(kinds.length, '?').join(',')})',
            kinds.toList(),
          );
    if (rows.isEmpty) return const [];
    final query = await client.embed(queryText);
    final qNorm = _norm(query);
    final scored = <RagHit>[];
    for (final r in rows) {
      final id = r['id'] as int;
      if (exclude.contains(id)) continue;
      final blob = r['embedding'] as Uint8List;
      final vec = _blobToFloat32(blob);
      if (vec.length != query.length) continue;
      final score = _cosine(query, vec, qNorm);
      scored.add(RagHit(
        id: id,
        sourceKind: r['source_kind'] as String,
        sourceId: r['source_id'] as String,
        text: r['text'] as String,
        score: score,
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).toList();
  }

  // ---------------------------------------------------------------------------
  // helpers

  Future<void> _embedAndStore(List<RagChunk> chunks) async {
    final db = _open;
    final insert = db.prepare(
      'INSERT OR REPLACE INTO chunks'
      '(source_kind, source_id, position, text, embedding) '
      'VALUES (?, ?, ?, ?, ?)',
    );
    try {
      for (final c in chunks) {
        final embedding = await client.embed(c.text);
        insert.execute([
          c.sourceKind,
          c.sourceId,
          c.position,
          c.text,
          _float32ToBlob(embedding),
        ]);
      }
    } finally {
      insert.dispose();
    }
  }

  void _pruneAbsentSources(Database db, Set<(String, String)> liveKeys) {
    final rows = db.select('SELECT DISTINCT source_kind, source_id FROM chunks');
    for (final r in rows) {
      final key = (r['source_kind'] as String, r['source_id'] as String);
      if (!liveKeys.contains(key)) {
        db
          ..execute(
            'DELETE FROM chunks WHERE source_kind=? AND source_id=?',
            [key.$1, key.$2],
          )
          ..execute(
            'DELETE FROM sources WHERE source_kind=? AND source_id=?',
            [key.$1, key.$2],
          );
      }
    }
  }

  /// Count sources whose on-disk fingerprint differs from the row in
  /// `sources`. Used by the RAG card to surface "⚠ Out of date — N
  /// sources changed". Sources present in [emulator] but missing from
  /// `sources` also count (they've never been indexed).
  int _stalenessCount(Emulator emulator) {
    final db = _open;
    final known = <(String, String), String>{
      for (final r in db.select(
          'SELECT source_kind, source_id, fingerprint FROM sources'))
        (r['source_kind'] as String, r['source_id'] as String):
            r['fingerprint'] as String,
    };
    var stale = 0;
    final docDir = Directory(p.join(projectDir, 'documents'));
    for (final d in emulator.documents) {
      final f = File(p.join(docDir.path, d.filename));
      if (!f.existsSync()) continue;
      final fp = _fingerprintFileSync(f);
      if (known[('doc', d.filename)] != fp) stale++;
    }
    // Symbol-/hook-level fingerprints are recomputed during rebuild;
    // here we only flag wholly missing rows as stale to avoid scanning
    // a 1k-symbol graph on every status read.
    final graph = emulator.cachedCallGraph;
    if (graph != null) {
      for (final name in graph.symbols.keys) {
        if (!known.containsKey(('symbol', name))) stale++;
      }
    }
    return stale;
  }

  bool _sourceUnchanged(String kind, String id, String fingerprint) {
    final db = _open;
    final row = db.select(
      'SELECT fingerprint FROM sources WHERE source_kind=? AND source_id=?',
      [kind, id],
    );
    if (row.isEmpty) return false;
    return row.first['fingerprint'] as String == fingerprint;
  }

  void _writeSourceFingerprint(String kind, String id, String fingerprint) {
    _open.execute(
      'INSERT OR REPLACE INTO sources(source_kind, source_id, fingerprint, '
      'indexed_at) VALUES (?, ?, ?, ?)',
      [kind, id, fingerprint, DateTime.now().millisecondsSinceEpoch],
    );
  }

  String? _readMeta(String key) {
    final row = _open.select('SELECT value FROM meta WHERE key=?', [key]);
    return row.isEmpty ? null : row.first['value'] as String;
  }

  void _writeMeta(String key, String value) {
    _open.execute(
      'INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  String _renderSymbolCard(cg.Symbol node, CallGraph? graph) {
    final callers = graph?.getCallers(node.name) ?? const <String>[];
    final callees = node.calledSymbols.keys.toList();
    return [
      'Symbol: ${node.name}',
      if (callers.isNotEmpty) 'Called by: ${callers.join(', ')}',
      if (callees.isNotEmpty) 'Calls: ${callees.join(', ')}',
    ].join('\n');
  }
}

class RagHit {
  const RagHit({
    required this.id,
    required this.sourceKind,
    required this.sourceId,
    required this.text,
    required this.score,
  });
  final int id;
  final String sourceKind;
  final String sourceId;
  final String text;
  final double score;
}

class RagRebuildEvent {
  const RagRebuildEvent({
    required this.phase,
    required this.done,
    required this.total,
  });
  final String phase;
  final int done;
  final int total;
}

/// Reduced view of a user-authored hook for RAG indexing. We don't pull
/// the full Artifact model here to keep the orchestrator layer free of
/// the artifact_database dependency on the RAG path's hot loop.
class UserHookEntry {
  const UserHookEntry({
    required this.id,
    required this.displayName,
    required this.body,
  });
  final String id;
  final String displayName;
  final String body;
}

/// Snapshot of Ghidra-derived rows pulled from `ArtifactDatabase`
/// at the start of a rebuild pass. Pre-formatted into the exact
/// strings that get chunked + embedded, so the chunking loop is
/// straight-line. Data symbols arrive already grouped into batches
/// (see [_snapshotGhidraInputs]) since 20 globals per chunk reads
/// more usefully than 20 single-line chunks.
class _GhidraRagInputs {
  const _GhidraRagInputs({
    required this.decompilations,
    required this.dataTypes,
    required this.dataSymbolBatchIds,
    required this.dataSymbolBatchTexts,
    required this.hasMemoryMap,
    required this.memoryMapText,
  });

  final List<GhidraDecompilation> decompilations;
  final List<GhidraDataType> dataTypes;
  final List<String> dataSymbolBatchIds;
  final List<String> dataSymbolBatchTexts;
  final bool hasMemoryMap;
  final String memoryMapText;

  /// Number of (source_kind, source_id) units this snapshot will
  /// produce — used to size the rebuild progress total.
  int get totalWorkUnits =>
      decompilations.length +
      dataTypes.length +
      dataSymbolBatchIds.length +
      (hasMemoryMap ? 1 : 0);
}

// -----------------------------------------------------------------------------
// embedding blob + cosine helpers

Uint8List _float32ToBlob(Float32List v) =>
    v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);

Float32List _blobToFloat32(Uint8List bytes) {
  // Embedding rows are always written by [_float32ToBlob], which
  // produces a length divisible by 4. SQLite hands us a fresh buffer
  // each select, so we can wrap it without copying.
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(bytes.lengthInBytes ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

double _norm(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  return s == 0 ? 1 : s;
}

double _cosine(Float32List a, Float32List b, double aNorm) {
  var dot = 0.0;
  var bNorm = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    bNorm += b[i] * b[i];
  }
  if (bNorm == 0) return 0;
  return dot / (math.sqrt(aNorm) * math.sqrt(bNorm));
}

Future<String> _fingerprintFile(File f) async =>
    sha256.convert(await f.readAsBytes()).toString();

String _fingerprintFileSync(File f) =>
    sha256.convert(f.readAsBytesSync()).toString();

String _hashString(String s) =>
    sha256.convert(s.codeUnits).toString();
