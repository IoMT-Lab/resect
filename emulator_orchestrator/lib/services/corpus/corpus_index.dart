import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../rag/embedding_math.dart';
import '../rag/rag_index.dart' show RagHit;
import '../rag/retriever.dart';

/// Chunk counts and provenance summary for one chip corpus.
class CorpusStatus {
  const CorpusStatus({
    required this.corpusKey,
    required this.chunkCount,
    required this.chunkCountsByKind,
    required this.itemStatuses,
    required this.embeddingModels,
    required this.ftsAvailable,
  });

  final String corpusKey;
  final int chunkCount;
  final Map<String, int> chunkCountsByKind;

  /// item_key → status (planned/downloaded/extracted/ingested/failed/
  /// skipped_optional).
  final Map<String, String> itemStatuses;

  /// Distinct embedding models present — more than one (or one that
  /// isn't the configured model) means re-embedding is needed.
  final Set<String> embeddingModels;

  final bool ftsAvailable;

  static const empty = CorpusStatus(
    corpusKey: '',
    chunkCount: 0,
    chunkCountsByKind: {},
    itemStatuses: {},
    embeddingModels: {},
    ftsAvailable: false,
  );
}

/// The shared per-chip corpus store: SDK source, SVD register maps, and
/// vendor PDFs, chunked + embedded once and retrieved by every project
/// on that chip family.
///
/// Deliberately its own sqlite (one `corpus.db` per family directory),
/// NOT an extension of the per-project RagIndex: this store is
/// versioned (`PRAGMA user_version`), records the embedding model per
/// chunk (a model change is detected, never a silent cosine mismatch),
/// keeps fetch provenance, and prefilters retrieval in SQL so tens of
/// thousands of chunks stay fast. Embedding is the caller's job
/// (corpus_ingestor.dart) — this class stores and retrieves.
class CorpusIndex implements Retriever {
  CorpusIndex({
    required this.dbPath,
    required this.corpusKey,
    required Future<Float32List> Function(String text) embedQuery,
    this.embeddingModel = 'nomic-embed-text',
    this.part,
    this.defaultKinds,
  }) : _embedQuery = embedQuery;

  final String dbPath;
  final String corpusKey;
  final String embeddingModel;

  /// When set, retrieval scopes to `part IS NULL OR part = ?`.
  final String? part;

  /// Kinds used when a caller doesn't pass any (lets consumers stay
  /// ignorant of corpus kind names).
  final Set<String>? defaultKinds;

  /// FTS identifier terms for the next [retrieve] call's SQL prefilter;
  /// set by callers that built a [RetrievalQuery]. Consumed per call.
  Set<String> pendingFtsTerms = const {};

  final Future<Float32List> Function(String) _embedQuery;

  Database? _db;
  bool _ftsAvailable = false;

  static const schemaVersion = 1;

  /// Hard bound on rows entering the in-memory cosine re-rank.
  static const prefilterCap = 2000;

  Database open() {
    final existing = _db;
    if (existing != null) return existing;
    File(dbPath).parent.createSync(recursive: true);
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA journal_mode = WAL');

    final version =
        db.select('PRAGMA user_version').first.columnAt(0) as int;
    if (version == 0) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS meta(
          key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS fetch_items(
          item_key TEXT PRIMARY KEY,
          url TEXT NOT NULL,
          kind TEXT NOT NULL,
          license_note TEXT NOT NULL,
          adapter_version INTEGER NOT NULL,
          sha256 TEXT,
          bytes INTEGER,
          fetched_at INTEGER,
          status TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sources(
          source_id TEXT PRIMARY KEY,
          item_key TEXT NOT NULL,
          fingerprint TEXT NOT NULL,
          part TEXT,
          indexed_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS chunks(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          kind TEXT NOT NULL,
          part TEXT,
          text TEXT NOT NULL,
          embedding BLOB NOT NULL,
          embedding_model TEXT NOT NULL,
          embedding_dim INTEGER NOT NULL,
          UNIQUE(source_id, position));
        CREATE INDEX IF NOT EXISTS chunks_kind ON chunks(kind);
        CREATE INDEX IF NOT EXISTS chunks_part ON chunks(part);
      ''');
      db.execute('PRAGMA user_version = $schemaVersion');
    }
    // Future migrations: switch on `version` here.

    // FTS5 is compiled into most distro sqlite builds but not all —
    // probe, record, and degrade to a bounded non-FTS prefilter.
    try {
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts
          USING fts5(text, content='chunks', content_rowid='id');
        -- External-content sync: plain INSERT/DELETE on chunks keeps the
        -- FTS index current without callers touching chunks_fts.
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
          INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
          INSERT INTO chunks_fts(chunks_fts, rowid, text)
            VALUES('delete', old.id, old.text);
        END;
      ''');
      _ftsAvailable = true;
    } catch (_) {
      _ftsAvailable = false;
    }
    db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('fts_available', ?)",
        [_ftsAvailable ? '1' : '0']);
    db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('corpus_key', ?)",
        [corpusKey]);

    _db = db;
    return db;
  }

  bool get ftsAvailable {
    open();
    return _ftsAvailable;
  }

  void close() {
    _db?.dispose();
    _db = null;
  }

  /// Retrieval: SQL prefilter (kind + part + embedding model, FTS terms
  /// when available, hard LIMIT [prefilterCap]) then in-memory cosine
  /// re-rank. Bounded by construction.
  @override
  Future<List<RagHit>> retrieve(
    String queryText, {
    int topK = 10,
    Set<String>? kinds,
    Set<int> exclude = const {},
  }) async {
    final db = open();
    final effectiveKinds = kinds ?? defaultKinds;
    final ftsTerms = pendingFtsTerms;
    pendingFtsTerms = const {};

    final where = <String>['embedding_model = ?'];
    final args = <Object?>[embeddingModel];
    if (effectiveKinds != null && effectiveKinds.isNotEmpty) {
      where.add(
          'kind IN (${List.filled(effectiveKinds.length, '?').join(',')})');
      args.addAll(effectiveKinds);
    }
    if (part != null) {
      where.add('(part IS NULL OR part = ?)');
      args.add(part);
    }

    ResultSet rows;
    if (_ftsAvailable && ftsTerms.isNotEmpty) {
      final match = ftsTerms.map((t) => '"$t"').join(' OR ');
      rows = db.select('''
        SELECT c.id, c.kind, c.source_id, c.text, c.embedding
        FROM chunks_fts f JOIN chunks c ON c.id = f.rowid
        WHERE chunks_fts MATCH ? AND ${where.join(' AND ')}
        ORDER BY bm25(chunks_fts) LIMIT $prefilterCap
      ''', [match, ...args]);
      // FTS can legitimately miss (odd identifiers) — fall through to
      // the bounded scan rather than returning nothing.
      if (rows.isEmpty) {
        rows = _boundedScan(db, where, args);
      }
    } else {
      rows = _boundedScan(db, where, args);
    }
    if (rows.isEmpty) return const [];

    final query = await _embedQuery(queryText);
    final qNorm = sumOfSquares(query);
    final scored = <RagHit>[];
    for (final row in rows) {
      final id = row['id'] as int;
      if (exclude.contains(id)) continue;
      final vec = blobToFloat32(row['embedding'] as Uint8List);
      if (vec.length != query.length) continue;
      scored.add(RagHit(
        id: id,
        sourceKind: row['kind'] as String,
        sourceId: row['source_id'] as String,
        text: row['text'] as String,
        score: cosine(query, vec, qNorm),
        origin: 'corpus',
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(topK).toList();
  }

  ResultSet _boundedScan(Database db, List<String> where, List<Object?> args) =>
      db.select('''
        SELECT id, kind, source_id, text, embedding FROM chunks
        WHERE ${where.join(' AND ')} LIMIT $prefilterCap
      ''', args);

  CorpusStatus status() {
    final db = open();
    final total =
        db.select('SELECT COUNT(*) c FROM chunks').first['c'] as int;
    final byKind = <String, int>{
      for (final r
          in db.select('SELECT kind, COUNT(*) c FROM chunks GROUP BY kind'))
        r['kind'] as String: r['c'] as int
    };
    final items = <String, String>{
      for (final r in db.select('SELECT item_key, status FROM fetch_items'))
        r['item_key'] as String: r['status'] as String
    };
    final models = <String>{
      for (final r
          in db.select('SELECT DISTINCT embedding_model m FROM chunks'))
        r['m'] as String
    };
    return CorpusStatus(
      corpusKey: corpusKey,
      chunkCount: total,
      chunkCountsByKind: byKind,
      itemStatuses: items,
      embeddingModels: models,
      ftsAvailable: _ftsAvailable,
    );
  }
}
