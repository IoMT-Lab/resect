import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One chunk of indexable text plus a stable key into the source it came from.
///
/// Produced by [RagChunker] and consumed by `RagIndex.rebuildFor`, which
/// embeds each chunk's [text] and persists the row alongside [sourceKind],
/// [sourceId], and [position].
class RagChunk {
  const RagChunk({
    required this.sourceKind,
    required this.sourceId,
    required this.position,
    required this.text,
  });

  /// `'doc' | 'symbol' | 'hook' | 'src'`. Drives the SQL filter for
  /// retrieval and lets the RAG card break the chunk count down by kind.
  final String sourceKind;

  /// Stable identifier within [sourceKind] — e.g. doc filename, symbol
  /// name, hook artifact id. Combined with [sourceKind] and [position]
  /// to detect re-chunking of the same source.
  final String sourceId;

  /// Chunk index within the source, 0-based. Stays stable across
  /// rebuilds so the index can update-in-place per source.
  final int position;

  /// Plain text fed both to the embedding model (at index time) and into
  /// the LLM prompt (at retrieve time).
  final String text;
}

/// Extracts text from a project document and splits it into ~500-token
/// chunks with ~50-token overlap for embedding.
///
/// Text files (`.txt`/`.md`/source code) are read directly. PDFs shell
/// out to `pdftotext` (from poppler-utils, installed by the LLM
/// module). Unknown extensions are tried as plain text, on the theory
/// that a stray `.cfg`/`.ld`/`.s` should still be indexable.
///
/// The 1-token-≈-4-chars heuristic is intentionally rough — we're not
/// trying to match the inference model's tokenizer, just keep chunks
/// inside its context window. A real tokenizer dependency would buy
/// little here.
class RagChunker {
  const RagChunker({this.pdftotextPath = 'pdftotext'});

  /// Path to the `pdftotext` binary. Falls back to PATH lookup when the
  /// caller passes the default; tests override it.
  final String pdftotextPath;

  static const _targetChars = 2000; // ~500 tokens at 4 chars/token
  static const _overlapChars = 200; // ~50 tokens at 4 chars/token

  /// Chunk a single document file. [sourceId] is normally the doc's
  /// filename — the same string the RAG index will store so it can
  /// look up "all chunks from this doc" later.
  Future<List<RagChunk>> chunkDocument(
    File file, {
    required String sourceId,
  }) async {
    final ext = p.extension(file.path).toLowerCase();
    final text = ext == '.pdf'
        ? await _pdftotext(file.path)
        : await file.readAsString();
    return _split(text, sourceKind: 'doc', sourceId: sourceId);
  }

  /// Chunk a string that's already in memory — useful for symbol cards
  /// and hook bodies that don't live on disk as standalone files.
  List<RagChunk> chunkText(
    String text, {
    required String sourceKind,
    required String sourceId,
  }) =>
      _split(text, sourceKind: sourceKind, sourceId: sourceId);

  /// Shell out to `pdftotext -layout <input> -`, capturing stdout.
  Future<String> _pdftotext(String path) async {
    final r = await Process.run(pdftotextPath, ['-layout', path, '-']);
    if (r.exitCode != 0) {
      throw RagChunkerException(
        'pdftotext exited ${r.exitCode} on $path: ${r.stderr}',
      );
    }
    return r.stdout as String;
  }

  /// Sliding-window split. Whitespace-normalises first so chunk boundaries
  /// don't fall inside `\n   \n` blocks (common in PDF extraction).
  List<RagChunk> _split(
    String raw, {
    required String sourceKind,
    required String sourceId,
  }) {
    final text = raw.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (text.isEmpty) return const [];
    final chunks = <RagChunk>[];
    var start = 0;
    var position = 0;
    while (start < text.length) {
      final end = (start + _targetChars).clamp(0, text.length);
      // Snap forward to the next paragraph/sentence boundary so the
      // chunk doesn't end mid-word. Cap the look-ahead so we don't
      // glue two giant paragraphs together at the tail.
      final snap = _snapForward(text, end);
      chunks.add(RagChunk(
        sourceKind: sourceKind,
        sourceId: sourceId,
        position: position,
        text: text.substring(start, snap).trim(),
      ));
      if (snap >= text.length) break;
      start = (snap - _overlapChars).clamp(0, text.length);
      position++;
    }
    return chunks;
  }

  static int _snapForward(String text, int from) {
    const lookahead = 200;
    final limit = (from + lookahead).clamp(0, text.length);
    for (var i = from; i < limit; i++) {
      if (text[i] == '\n' || text[i] == '.') return i + 1;
    }
    // No nice boundary — just snap to the next space so we don't cut a word.
    for (var i = from; i < limit; i++) {
      if (text[i] == ' ') return i;
    }
    return from;
  }
}

class RagChunkerException implements Exception {
  RagChunkerException(this.message);
  final String message;
  @override
  String toString() => 'RagChunkerException: $message';
}
