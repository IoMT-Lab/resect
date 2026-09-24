import 'dart:io';
import 'dart:typed_data';

import 'package:emulator_orchestrator/services/corpus/corpus_index.dart';
import 'package:emulator_orchestrator/services/rag/embedding_math.dart';
import 'package:test/test.dart';

/// Deterministic bag-of-words embedding: each lowercased word bumps a
/// hashed dimension, so texts sharing words get similar vectors (a
/// hash-random embedder would make cosine meaningless and the retrieval
/// assertions vacuous). No ollama.
Float32List fakeEmbed(String text) {
  final v = Float32List(64);
  for (final w in text.toLowerCase().split(RegExp(r'\W+'))) {
    if (w.isEmpty) continue;
    v[w.hashCode.abs() % 64] += 1;
  }
  return v;
}

void main() {
  late Directory tmp;
  late CorpusIndex index;

  CorpusIndex makeIndex(String key, {String model = 'nomic-embed-text'}) =>
      CorpusIndex(
        dbPath: '${tmp.path}/$key/corpus.db',
        corpusKey: key,
        embeddingModel: model,
        embedQuery: (t) async => fakeEmbed(t),
      );

  void insert(CorpusIndex idx,
      {required String sourceId,
      required String kind,
      String? part,
      required List<String> texts,
      String model = 'nomic-embed-text'}) {
    final db = idx.open();
    db.execute('BEGIN');
    for (var i = 0; i < texts.length; i++) {
      final e = fakeEmbed(texts[i]);
      db.execute(
        'INSERT INTO chunks(source_id, position, kind, part, text, '
        'embedding, embedding_model, embedding_dim) VALUES(?,?,?,?,?,?,?,?)',
        [sourceId, i, kind, part, texts[i], float32ToBlob(e), model, 16],
      );
    }
    db.execute('COMMIT');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('corpus_test');
    index = makeIndex('st.stm32wb0');
  });

  tearDown(() {
    index.close();
    tmp.deleteSync(recursive: true);
  });

  test('creates a versioned schema', () {
    final db = index.open();
    final v = db.select('PRAGMA user_version').first.columnAt(0);
    expect(v, CorpusIndex.schemaVersion);
  });

  test('retrieve returns the best cosine match, scoped by kind', () async {
    insert(index,
        sourceId: 'svd:USART1',
        kind: 'svd_register',
        texts: ['Peripheral USART1 CR1 UE TE', 'Peripheral SPI1 CR1']);
    insert(index,
        sourceId: 'hdr.h', kind: 'sdk_header', texts: ['unrelated header']);

    final hits = await index
        .retrieve('Peripheral USART1 CR1', kinds: {'svd_register'}, topK: 1);
    expect(hits, hasLength(1));
    expect(hits.first.sourceKind, 'svd_register');
    expect(hits.first.origin, 'corpus');
    expect(hits.first.text, contains('USART1'));
  });

  test('embedding-model mismatch yields zero retrievable chunks',
      () async {
    insert(index,
        sourceId: 's', kind: 'svd_register', texts: ['x'],
        model: 'old-model');
    final hits = await index.retrieve('x', kinds: {'svd_register'});
    expect(hits, isEmpty, reason: 'configured model differs from stored');
    final status = index.status();
    expect(status.embeddingModels, {'old-model'});
  });

  test('part scoping excludes other-part chunks', () async {
    final idx = makeIndex('st.stm32wb0');
    // reopen with a part filter
    final scoped = CorpusIndex(
      dbPath: '${tmp.path}/st.stm32wb0/corpus.db',
      corpusKey: 'st.stm32wb0',
      part: 'STM32WB05',
      embedQuery: (t) async => fakeEmbed(t),
    );
    insert(idx,
        sourceId: 'a', kind: 'svd_register', part: 'STM32WB05',
        texts: ['wb05 usart']);
    insert(idx,
        sourceId: 'b', kind: 'svd_register', part: 'STM32WB09',
        texts: ['wb09 usart']);
    insert(idx,
        sourceId: 'c', kind: 'sdk_header', part: null, texts: ['shared hdr']);
    idx.close();

    final hits =
        await scoped.retrieve('usart', kinds: {'svd_register'}, topK: 5);
    expect(hits.map((h) => h.text), everyElement(isNot(contains('wb09'))));
    scoped.close();
  });

  test('scales: FTS prefilter finds the needle among 5000 chunks, bounded',
      () async {
    // The marker is the LAST row — a plain LIMIT-2000 scan by rowid
    // would never reach it. The FTS prefilter is what makes it
    // retrievable at scale; this asserts that mitigation actually works.
    final texts = [
      for (var i = 0; i < 5000; i++) 'filler chunk number $i lorem ipsum',
      'Peripheral USART1 CR1 UE TE uniquemarker',
    ];
    insert(index, sourceId: 'big', kind: 'sdk_source', texts: texts);
    if (!index.ftsAvailable) {
      markTestSkipped('sqlite build lacks FTS5');
      return;
    }
    index.pendingFtsTerms = {'uniquemarker', 'usart1'};
    final sw = Stopwatch()..start();
    final hits =
        await index.retrieve('uniquemarker USART1', kinds: {'sdk_source'});
    sw.stop();
    expect(hits.first.text, contains('uniquemarker'),
        reason: 'FTS surfaced the needle past the 2000-row cap');
    expect(sw.elapsed.inSeconds, lessThan(5));
    expect(index.status().chunkCount, 5001);
  });
}
