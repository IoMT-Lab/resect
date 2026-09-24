import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../rag/embedding_math.dart';
import '../rag/rag_chunker.dart';
import 'corpus_fetcher.dart';
import 'corpus_index.dart';
import 'corpus_store.dart';
import 'svd_distiller.dart';
import 'vendor_adapter.dart';

/// Chunks + embeds fetched corpus files into the corpus DB.
///
/// Kill-safe and resumable: each source file is embedded and written in
/// ONE transaction with its `sources` fingerprint row last, so an
/// interrupted run leaves whole sources or none. Re-running skips
/// sources whose sha256 is unchanged (same idiom as RagIndex.rebuildFor).
class CorpusIngestEvent {
  const CorpusIngestEvent(this.phase, {this.done = 0, this.total = 0});
  final String phase;
  final int done;
  final int total;
}

class CorpusIngestor {
  CorpusIngestor({
    required this.store,
    required this.index,
    required Future<List<Float32List>> Function(List<String>) embedBatch,
    this.chunker = const RagChunker(),
    this.svdDistiller = const SvdDistiller(),
    this.part,
    this.maxChunks = 40000,
    this.batchSize = 16,
  }) : _embedBatch = embedBatch;

  final CorpusStore store;
  final CorpusIndex index;
  final RagChunker chunker;
  final SvdDistiller svdDistiller;
  final String? part;
  final int maxChunks;
  final int batchSize;
  final Future<List<Float32List>> Function(List<String>) _embedBatch;

  Database get _db => index.open();

  /// Ingest the fetched items plus any files in the store's drop_in/.
  /// Emits progress; per-source transactional; resumable.
  Stream<CorpusIngestEvent> ingest(
    List<FetchedItem> fetched, {
    required String embeddingModel,
  }) async* {
    // Record item provenance/status first (outside the per-source txns).
    for (final f in fetched) {
      _db.execute('''
        INSERT OR REPLACE INTO fetch_items(item_key, url, kind, license_note,
          adapter_version, sha256, bytes, fetched_at, status)
        VALUES(?,?,?,?,?,?,?,?,?)
      ''', [
        f.item.key,
        f.item.url.toString(),
        f.item.kind.name,
        f.item.licenseNote,
        0,
        f.sha256,
        f.bytes,
        DateTime.now().millisecondsSinceEpoch,
        f.skipped ? 'skipped_optional' : 'extracted',
      ]);
    }

    // Gather ingest units: extracted files + drop_in/ PDFs.
    final units = <_IngestUnit>[];
    for (final f in fetched) {
      for (final rel in f.extractedPaths) {
        units.add(_IngestUnit(
          absPath: p.join(store.extractedDir, rel),
          sourceId: '${f.item.key}:$rel',
          itemKey: f.item.key,
          kind: _kindFor(f.item.kind, rel),
          part: f.item.part ?? part,
        ));
      }
    }
    final dropIn = Directory(store.dropInDir);
    if (dropIn.existsSync()) {
      for (final e in dropIn.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.pdf')) {
          units.add(_IngestUnit(
            absPath: e.path,
            sourceId: 'drop_in:${p.basename(e.path)}',
            itemKey: 'drop_in',
            kind: 'datasheet',
            part: part,
          ));
        }
      }
    }

    var chunkTotal = _db
        .select('SELECT COUNT(*) c FROM chunks')
        .first['c'] as int;
    var done = 0;
    for (final unit in units) {
      done++;
      store.heartbeat();
      yield CorpusIngestEvent('Embedding ${p.basename(unit.absPath)}',
          done: done, total: units.length);

      final file = File(unit.absPath);
      if (!file.existsSync()) continue;
      final fingerprint =
          sha256.convert(file.readAsBytesSync()).toString();
      if (_sourceUnchanged(unit.sourceId, fingerprint)) continue;
      if (chunkTotal >= maxChunks) {
        yield CorpusIngestEvent(
            'Chunk cap ($maxChunks) reached — stopping ingest',
            done: done, total: units.length);
        break;
      }

      final chunks = await _chunkUnit(unit);
      if (chunks.isEmpty) continue;

      // Embed in batches, then write the whole source atomically.
      final embeddings = <Float32List>[];
      for (var i = 0; i < chunks.length; i += batchSize) {
        final slice =
            chunks.sublist(i, (i + batchSize).clamp(0, chunks.length));
        embeddings.addAll(await _embedWithRetry(slice));
      }

      _db.execute('BEGIN');
      try {
        _db.execute('DELETE FROM chunks WHERE source_id = ?', [unit.sourceId]);
        for (var i = 0; i < chunks.length; i++) {
          final e = embeddings[i];
          _db.execute('''
            INSERT INTO chunks(source_id, position, kind, part, text,
              embedding, embedding_model, embedding_dim)
            VALUES(?,?,?,?,?,?,?,?)
          ''', [
            unit.sourceId,
            i,
            unit.kind,
            unit.part,
            chunks[i],
            float32ToBlob(e),
            embeddingModel,
            e.length,
          ]);
        }
        _db.execute('''
          INSERT OR REPLACE INTO sources(source_id, item_key, fingerprint,
            part, indexed_at) VALUES(?,?,?,?,?)
        ''', [
          unit.sourceId,
          unit.itemKey,
          fingerprint,
          unit.part,
          DateTime.now().millisecondsSinceEpoch,
        ]);
        _db.execute('COMMIT');
        chunkTotal += chunks.length;
      } catch (e) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }

    // Mark items whose sources all landed as ingested.
    for (final f in fetched.where((f) => !f.skipped)) {
      _db.execute(
          "UPDATE fetch_items SET status = 'ingested' WHERE item_key = ?",
          [f.item.key]);
    }
    yield CorpusIngestEvent('Done', done: units.length, total: units.length);
  }

  bool _sourceUnchanged(String sourceId, String fingerprint) {
    final row = _db.select(
        'SELECT fingerprint FROM sources WHERE source_id = ?', [sourceId]);
    return row.isNotEmpty && row.first['fingerprint'] == fingerprint;
  }

  Future<List<String>> _chunkUnit(_IngestUnit unit) async {
    final file = File(unit.absPath);
    final name = p.basename(unit.absPath);
    if (unit.kind == 'svd_register') {
      final peripherals =
          svdDistiller.distill(file.readAsStringSync(), part: unit.part ?? '');
      return [for (final pr in peripherals) pr.text];
    }
    if (unit.kind == 'datasheet' || unit.kind == 'ref_manual') {
      // PDF via the existing pdftotext-backed chunker.
      final chunks = await chunker.chunkDocument(file, sourceId: unit.sourceId);
      return [for (final c in chunks) c.text];
    }
    // Source/header: prefix a provenance header, then char-window chunk.
    final text = '// ${unit.itemKey} $name\n${file.readAsStringSync()}';
    return [
      for (final c
          in chunker.chunkText(text, sourceKind: unit.kind, sourceId: name))
        c.text
    ];
  }

  Future<List<Float32List>> _embedWithRetry(List<String> texts) async {
    try {
      return await _embedBatch(texts);
    } on Exception {
      // One retry, then let it propagate — the source's transaction
      // never opened, so nothing partial is written.
      return await _embedBatch(texts);
    }
  }

  String _kindFor(CorpusItemKind itemKind, String relPath) {
    switch (itemKind) {
      case CorpusItemKind.svd:
        return 'svd_register';
      case CorpusItemKind.datasheetPdf:
        return 'datasheet';
      case CorpusItemKind.referenceManualPdf:
        return 'ref_manual';
      case CorpusItemKind.sdkSource:
        return relPath.toLowerCase().endsWith('.h') ? 'sdk_header' : 'sdk_source';
    }
  }
}

class _IngestUnit {
  const _IngestUnit({
    required this.absPath,
    required this.sourceId,
    required this.itemKey,
    required this.kind,
    required this.part,
  });
  final String absPath;
  final String sourceId;
  final String itemKey;
  final String kind;
  final String? part;
}
