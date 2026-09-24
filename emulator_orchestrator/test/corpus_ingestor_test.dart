import 'dart:io';
import 'dart:typed_data';

import 'package:emulator_orchestrator/services/corpus/corpus_fetcher.dart';
import 'package:emulator_orchestrator/services/corpus/corpus_index.dart';
import 'package:emulator_orchestrator/services/corpus/corpus_ingestor.dart';
import 'package:emulator_orchestrator/services/corpus/corpus_store.dart';
import 'package:emulator_orchestrator/services/corpus/vendor_adapter.dart';
import 'package:test/test.dart';

Float32List fakeEmbed(String t) {
  final v = Float32List(8);
  for (final w in t.toLowerCase().split(RegExp(r'\W+'))) {
    if (w.isNotEmpty) v[w.hashCode.abs() % 8] += 1;
  }
  return v;
}

void main() {
  late Directory tmp;
  late CorpusStore store;
  late CorpusIndex index;

  FetchedItem svdItem(String rel) => FetchedItem(
        item: FetchItem(
          key: 'svd:STM32WB05',
          url: Uri.parse('https://x/STM32WB05.svd'),
          kind: CorpusItemKind.svd,
          licenseNote: 'test',
          part: 'STM32WB05',
        ),
        extractedPaths: [rel],
        sha256: 'abc',
        bytes: 100,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ingest_test');
    store = CorpusStore(
        rootDir: '${tmp.path}/st.stm32wb0', corpusKey: 'st.stm32wb0');
    store.ensureDirs();
    index = CorpusIndex(
      dbPath: store.dbPath,
      corpusKey: 'st.stm32wb0',
      embedQuery: (t) async => fakeEmbed(t),
    );
    // A tiny real SVD in extracted/.
    File('${store.extractedDir}/svd_STM32WB05.svd').writeAsStringSync('''
<device><name>STM32WB05</name><peripherals>
  <peripheral><name>USART1</name><baseAddress>0x40013800</baseAddress>
    <registers><register><name>CR1</name><addressOffset>0x0</addressOffset></register></registers>
  </peripheral>
</peripherals></device>''');
  });

  tearDown(() {
    index.close();
    tmp.deleteSync(recursive: true);
  });

  CorpusIngestor makeIngestor(
          {Future<List<Float32List>> Function(List<String>)? embed}) =>
      CorpusIngestor(
        store: store,
        index: index,
        part: 'STM32WB05',
        embedBatch: embed ??
            (texts) async => [for (final t in texts) fakeEmbed(t)],
      );

  test('ingests SVD into per-peripheral svd_register chunks', () async {
    await makeIngestor()
        .ingest([svdItem('svd_STM32WB05.svd')], embeddingModel: 'test-model')
        .drain<void>();
    final status = index.status();
    expect(status.chunkCountsByKind['svd_register'], 1);
    expect(status.itemStatuses['svd:STM32WB05'], 'ingested');
  });

  test('re-ingest with unchanged fingerprint is a no-op', () async {
    await makeIngestor()
        .ingest([svdItem('svd_STM32WB05.svd')], embeddingModel: 'm')
        .drain<void>();
    final first = index.status().chunkCount;
    var embedCalls = 0;
    await makeIngestor(embed: (texts) async {
      embedCalls++;
      return [for (final t in texts) fakeEmbed(t)];
    }).ingest([svdItem('svd_STM32WB05.svd')], embeddingModel: 'm').drain<void>();
    expect(index.status().chunkCount, first);
    expect(embedCalls, 0, reason: 'unchanged source is skipped before embed');
  });

  test('embed failure leaves the source unwritten (transaction invariant)',
      () async {
    var calls = 0;
    final ingestor = makeIngestor(embed: (texts) async {
      calls++;
      throw Exception('ollama down');
    });
    await expectLater(
      ingestor
          .ingest([svdItem('svd_STM32WB05.svd')], embeddingModel: 'm')
          .drain<void>(),
      throwsA(isA<Exception>()),
    );
    expect(calls, 2, reason: 'one retry then propagate');
    // Nothing partial written; a later successful run completes it.
    expect(index.status().chunkCount, 0);
    await makeIngestor()
        .ingest([svdItem('svd_STM32WB05.svd')], embeddingModel: 'm')
        .drain<void>();
    expect(index.status().chunkCount, 1);
  });
}
