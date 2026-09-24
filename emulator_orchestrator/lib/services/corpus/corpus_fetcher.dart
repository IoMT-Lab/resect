import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'corpus_store.dart';
import 'vendor_adapter.dart';

/// Progress from a corpus fetch (download + extract). Mirrors the
/// installer event triples so the UI/CLI render it the same way.
class CorpusFetchEvent {
  const CorpusFetchEvent(this.message, {this.done, this.total, this.itemKey});
  final String message;
  final int? done;
  final int? total;
  final String? itemKey;
}

/// Result of fetching one item — its extracted files (relative to the
/// store's extractedDir) tagged with the item they came from, or a
/// recorded skip for an optional item that failed.
class FetchedItem {
  const FetchedItem({
    required this.item,
    required this.extractedPaths,
    required this.sha256,
    required this.bytes,
    this.skippedReason,
  });
  final FetchItem item;

  /// Extracted file paths relative to `extractedDir`.
  final List<String> extractedPaths;
  final String? sha256;
  final int bytes;

  /// Non-null when an optional item failed and was recorded rather than
  /// aborting the fetch.
  final String? skippedReason;

  bool get skipped => skippedReason != null;
}

/// Downloads a [FetchPlan]'s items and extracts the glob-kept subtrees
/// into the store. Pure `dart:io` HttpClient + `package:archive`
/// (GZip+Tar) — no curl/git/unzip binaries in the image. Single files
/// (SVDs, PDFs) are saved as-is.
class CorpusFetcher {
  CorpusFetcher({required this.store, HttpClient? httpClient})
      : _http = httpClient ?? HttpClient();

  final CorpusStore store;
  final HttpClient _http;

  static const _perFileCapBytes = 512 * 1024;

  Stream<CorpusFetchEvent> fetch(FetchPlan plan) async* {
    store.ensureDirs();
    yield CorpusFetchEvent('Planning ${plan.items.length} item(s)…');

    for (final item in plan.items) {
      yield CorpusFetchEvent('Downloading ${item.key}…', itemKey: item.key);
      try {
        final rawFile = File(p.join(store.rawDir, _safeName(item)));
        final bytes = await _download(rawFile, item.url, (d, t) {});
        final digest = sha256.convert(rawFile.readAsBytesSync()).toString();

        List<String> extracted;
        if (item.kind == CorpusItemKind.sdkSource) {
          yield CorpusFetchEvent('Extracting ${item.key}…', itemKey: item.key);
          extracted = _extractArchive(rawFile, item);
          rawFile.deleteSync(); // keep only the glob-kept subtree
        } else {
          // Single file (SVD/PDF): move into extracted/ under its key.
          final dest = File(p.join(store.extractedDir, _singleName(item)));
          dest.parent.createSync(recursive: true);
          rawFile.renameSync(dest.path);
          extracted = [p.relative(dest.path, from: store.extractedDir)];
        }
        yield _ItemDone(FetchedItem(
          item: item,
          extractedPaths: extracted,
          sha256: digest,
          bytes: bytes,
        ));
      } on Exception catch (e) {
        if (item.optional) {
          yield CorpusFetchEvent(
              'Skipped optional ${item.key}: $e '
              '(drop the file into ${store.dropInDir} to include it)',
              itemKey: item.key);
          yield _ItemDone(FetchedItem(
            item: item,
            extractedPaths: const [],
            sha256: null,
            bytes: 0,
            skippedReason: '$e',
          ));
        } else {
          throw CorpusFetchException('Required item ${item.key} failed: $e');
        }
      }
    }
    yield const CorpusFetchEvent('Download complete.');
  }

  Future<int> _download(
      File dest, Uri url, void Function(int, int) onProgress) async {
    dest.parent.createSync(recursive: true);
    final req = await _http.getUrl(url);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw CorpusFetchException('$url returned HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength;
    final sink = dest.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }
    return received;
  }

  /// Extract only archive entries matching the item's keep-globs, each
  /// capped at [_perFileCapBytes], into `extractedDir/<item.key sans
  /// prefix>/…`. Uses pure-Dart GZip+Tar decoders.
  List<String> _extractArchive(File archiveFile, FetchItem item) {
    final bytes = archiveFile.readAsBytesSync();
    final tar = TarDecoder()
        .decodeBytes(GZipDecoder().decodeBytes(bytes));
    final subdir = item.key.replaceAll(':', '_');
    final matchers = [for (final r in item.keep) _Glob(r.glob)];
    final kept = <String>[];

    for (final entry in tar) {
      if (!entry.isFile) continue;
      if (!matchers.any((m) => m.matches(entry.name))) continue;
      final content = entry.content as List<int>;
      if (content.length > _perFileCapBytes) continue;
      // Strip the archive's leading top-level dir for a stable layout.
      final rel = entry.name.contains('/')
          ? entry.name.substring(entry.name.indexOf('/') + 1)
          : entry.name;
      final out = File(p.join(store.extractedDir, subdir, rel));
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(content);
      kept.add(p.relative(out.path, from: store.extractedDir));
    }
    return kept;
  }

  String _safeName(FetchItem item) {
    final base = item.key.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    return item.kind == CorpusItemKind.sdkSource ? '$base.tar.gz' : base;
  }

  String _singleName(FetchItem item) {
    final ext = switch (item.kind) {
      CorpusItemKind.svd => '.svd',
      CorpusItemKind.datasheetPdf ||
      CorpusItemKind.referenceManualPdf =>
        '.pdf',
      _ => '',
    };
    return '${item.key.replaceAll(':', '_')}$ext';
  }

  void close() => _http.close(force: true);
}

/// Internal event carrying a completed [FetchedItem] to the ingestor.
class _ItemDone extends CorpusFetchEvent {
  const _ItemDone(this.fetched) : super('item done');
  final FetchedItem fetched;
}

/// A completed-item event, if this is one (the ingestor pulls these).
FetchedItem? fetchedItemOf(CorpusFetchEvent e) =>
    e is _ItemDone ? e.fetched : null;

/// Minimal glob: supports `**` (any depth) and `*` (one segment),
/// anchored to the full archive path. Enough for the adapters' rules.
class _Glob {
  _Glob(String glob) : _re = _compile(glob);
  final RegExp _re;

  bool matches(String path) => _re.hasMatch(path);

  static RegExp _compile(String glob) {
    final sb = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          sb.write('.*');
          i++;
        } else {
          sb.write('[^/]*');
        }
      } else {
        sb.write(RegExp.escape(c));
      }
    }
    sb.write('\$');
    return RegExp(sb.toString());
  }
}

class CorpusFetchException implements Exception {
  CorpusFetchException(this.message);
  final String message;
  @override
  String toString() => 'CorpusFetchException: $message';
}
