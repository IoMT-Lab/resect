import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../data/models/call_graph.dart';

/// Identity checks binding a [CallGraph] to the firmware it was
/// extracted from.
///
/// A cached call graph (in a `.emu` file or a live provider) carries the
/// SHA-256 of its source ELF in [CallGraph.elfHash]. Nothing else about
/// the graph is trustworthy as identity — not the path it was extracted
/// from (files get replaced), and not "it was next to this firmware in
/// the project" (stale provider state crosses project switches). Every
/// consumer that reaches for a cached graph goes through these helpers
/// and regenerates on mismatch. Observed failure this prevents: an
/// auto-tune session emulating one firmware while the LLM layer reasoned
/// over another firmware's cached graph, silently redirecting hooks to
/// symbols that don't exist in the running binary.

/// SHA-256 hex digest of the file at [path]. The same digest
/// `ArtifactLibraryService.hashElfFile` produces (that method delegates
/// here), so graph stamps compare directly against firmware-record
/// hashes.
Future<String> sha256OfFile(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('File not found', path);
  }
  return sha256.convert(await file.readAsBytes()).toString();
}

/// Whether [graph] was extracted from the exact bytes currently at
/// [elfPath]. An unstamped graph (null [CallGraph.elfHash] — pre-stamp
/// `.emu` files) never matches: it cannot be validated, so it must be
/// regenerated.
Future<bool> callGraphMatchesElf(CallGraph graph, String elfPath) async {
  final stamp = graph.elfHash;
  if (stamp == null) return false;
  return stamp == await sha256OfFile(elfPath);
}

/// Resolve a call graph for [elfPath], trusting candidates only when
/// their stamp matches the file's current content: [cached] first (the
/// project's persisted graph), then [fallback] (a live provider value),
/// else [generate] a fresh one. Rejected candidates are logged to stderr
/// with both hashes so a poisoned cache is visible, never silent.
Future<CallGraph> ensureCallGraphForElf({
  required String elfPath,
  required Future<CallGraph> Function(String elfPath) generate,
  CallGraph? cached,
  CallGraph? fallback,
}) async {
  final actual = await sha256OfFile(elfPath);
  for (final (label, candidate) in [('cached', cached), ('live', fallback)]) {
    if (candidate == null) continue;
    if (candidate.elfHash == actual) return candidate;
    stderr.writeln(
        '[CallGraphGuard] Rejecting $label call graph for $elfPath: '
        'graph stamp ${candidate.elfHash ?? '(unstamped)'} != ELF sha256 '
        '$actual (graph extracted from ${candidate.elfPath}); '
        'regenerating.');
  }
  return generate(elfPath);
}
