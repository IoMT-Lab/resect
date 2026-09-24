import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Owns the on-disk layout of one chip family's corpus and its advisory
/// lock. One directory per corpusKey under `<configDir>/corpus/`:
///
/// ```
/// <corpusKey>/
///   raw/          downloaded archives (deleted after extract)
///   extracted/    the glob-kept SDK subtrees + SVDs
///   drop_in/      user-supplied PDFs, ingested like fetched items
///   corpus.db     chunks + embeddings + provenance
///   corpus.lock   {pid, host, startedAt}; mtime is the heartbeat
/// ```
class CorpusStore {
  CorpusStore({required this.rootDir, required this.corpusKey});

  /// `<configDir>/corpus/<corpusKey>`.
  final String rootDir;
  final String corpusKey;

  String get rawDir => p.join(rootDir, 'raw');
  String get extractedDir => p.join(rootDir, 'extracted');
  String get dropInDir => p.join(rootDir, 'drop_in');
  String get dbPath => p.join(rootDir, 'corpus.db');
  String get lockPath => p.join(rootDir, 'corpus.lock');

  /// A fetch is considered dead if its lock heartbeat is older than this.
  static const staleLockAfter = Duration(minutes: 10);

  void ensureDirs() {
    for (final d in [rootDir, rawDir, extractedDir, dropInDir]) {
      Directory(d).createSync(recursive: true);
    }
  }

  /// Acquire the fetch lock. Returns false when another live fetch holds
  /// it (heartbeat within [staleLockAfter]); a stale lock is stolen with
  /// [onStealStale] invoked. Idempotent ingestion makes a rare race
  /// harmless anyway.
  bool acquireLock({void Function(String reason)? onStealStale}) {
    ensureDirs();
    final lock = File(lockPath);
    if (lock.existsSync()) {
      final age = DateTime.now().difference(lock.lastModifiedSync());
      if (age < staleLockAfter) return false;
      onStealStale?.call('stale lock (${age.inMinutes} min old) — stealing');
    }
    lock.writeAsStringSync(jsonEncode({
      'pid': pid,
      'host': Platform.localHostname,
      'started_at': DateTime.now().toIso8601String(),
    }));
    return true;
  }

  /// Touch the lock so a long ingest doesn't look stale.
  void heartbeat() {
    final lock = File(lockPath);
    if (lock.existsSync()) lock.setLastModifiedSync(DateTime.now());
  }

  void releaseLock() {
    final lock = File(lockPath);
    if (lock.existsSync()) lock.deleteSync();
  }

  /// Total bytes on disk for this corpus (for size accounting/prune).
  int diskBytes() {
    var total = 0;
    final dir = Directory(rootDir);
    if (!dir.existsSync()) return 0;
    for (final e in dir.listSync(recursive: true)) {
      if (e is File) total += e.lengthSync();
    }
    return total;
  }
}
