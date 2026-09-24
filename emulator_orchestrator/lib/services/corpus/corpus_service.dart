import 'dart:io';
import 'dart:typed_data';

import '../../core/app_paths.dart';
import '../../data/models/chip_identity.dart';
import '../llm/llm_client.dart';
import 'corpus_fetcher.dart';
import 'corpus_index.dart';
import 'corpus_ingestor.dart';
import 'corpus_store.dart';
import 'vendor_adapter.dart';
import 'vendor_adapter_registry.dart';

/// Progress event during an end-to-end fetch (planning → download →
/// extract → chunk → embed). One stream drives both the CLI printout
/// and the UI dialog so their behavior can't diverge.
class CorpusServiceEvent {
  const CorpusServiceEvent(this.message, {this.done = 0, this.total = 0});
  final String message;
  final int done;
  final int total;
}

/// Façade tying detection → adapter plan → fetch → ingest → retrieval
/// into the operations the CLI and UI both perform. Keeps the store,
/// index, fetcher, and ingestor wiring in one place so "fetch the
/// corpus" means exactly one code path everywhere.
class CorpusService {
  CorpusService({
    required this.client,
    String? corpusRoot,
  }) : corpusRoot = corpusRoot ?? AppPaths.corpusDir;

  final LlmClient client;
  final String corpusRoot;

  CorpusStore storeFor(ChipIdentity chip) => CorpusStore(
        rootDir: '$corpusRoot/${chip.corpusKey}',
        corpusKey: chip.corpusKey!,
      );

  /// Open a retrieval index over an already-fetched corpus, or null
  /// when the chip has no adapter, no corpus dir, or no chunks.
  CorpusIndex? openIndex(ChipIdentity chip, {String? part}) {
    if (chip.corpusKey == null) return null;
    final store = storeFor(chip);
    if (!File(store.dbPath).existsSync()) return null;
    final index = CorpusIndex(
      dbPath: store.dbPath,
      corpusKey: chip.corpusKey!,
      embeddingModel: client.embeddingModel,
      part: part ?? chip.part,
      embedQuery: client.embed,
    );
    if (index.status().chunkCount == 0) {
      index.close();
      return null;
    }
    return index;
  }

  /// The adapter's fetch plan for [chip], or null when no adapter
  /// covers it (a normal state — identity known, no curated sources).
  FetchPlan? planFor(ChipIdentity chip) {
    final adapter = adapterFor(chip);
    if (adapter == null) return null;
    return adapter.plan(chip);
  }

  /// Run [plan] end to end: acquire the lock, download+extract, chunk +
  /// embed into the corpus DB. Emits progress. Throws if a required
  /// item fails or another live fetch holds the lock.
  Stream<CorpusServiceEvent> fetchAndIngest(
    ChipIdentity chip,
    FetchPlan plan,
  ) async* {
    final store = storeFor(chip);
    if (!store.acquireLock(
        onStealStale: (r) => stderr.writeln('[corpus] $r'))) {
      throw StateError(
          'Another fetch is in progress for ${chip.corpusKey}.');
    }
    try {
      final fetcher = CorpusFetcher(store: store);
      final index = CorpusIndex(
        dbPath: store.dbPath,
        corpusKey: chip.corpusKey!,
        embeddingModel: client.embeddingModel,
        embedQuery: client.embed,
      );
      final fetched = <FetchedItem>[];
      try {
        await for (final e in fetcher.fetch(plan)) {
          final item = fetchedItemOf(e);
          if (item != null) {
            fetched.add(item);
          } else {
            yield CorpusServiceEvent(e.message,
                done: e.done ?? 0, total: e.total ?? 0);
          }
        }

        final ingestor = CorpusIngestor(
          store: store,
          index: index,
          part: chip.part,
          embedBatch: client.embedBatch,
        );
        await for (final e in ingestor.ingest(fetched,
            embeddingModel: client.embeddingModel)) {
          yield CorpusServiceEvent(e.phase, done: e.done, total: e.total);
        }
      } finally {
        index.close();
        fetcher.close();
      }
    } finally {
      store.releaseLock();
    }
  }

  /// Status snapshot for a chip's corpus, or null when nothing fetched.
  CorpusStatus? statusFor(ChipIdentity chip) {
    final index = openIndex(chip);
    if (index == null) return null;
    final status = index.status();
    index.close();
    return status;
  }
}

/// Signature the façade needs from an embedder — lets tests inject a
/// fake without a live LlmClient.
typedef EmbedFn = Future<Float32List> Function(String);
