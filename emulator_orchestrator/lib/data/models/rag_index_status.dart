/// Snapshot of the per-project RAG index state, surfaced in the
/// Library tab's RAG INDEX card.
///
/// The actual index (a SQLite store of embedded chunks) is built
/// lazily — until [RagIndex.rebuildFor] runs, [lastBuiltAt] is null
/// and [chunkCount] is zero. The card reads this status to decide
/// whether to show "Never built", "Up to date", or
/// "⚠ Out of date — N sources changed".
class RagIndexStatus {
  const RagIndexStatus({
    required this.lastBuiltAt,
    required this.chunkCount,
    required this.chunkCountsByKind,
    required this.staleSourceCount,
    required this.inProgressPhase,
  });

  /// When the index was last successfully (re)built. Null until the
  /// first build completes.
  final DateTime? lastBuiltAt;

  /// Total chunks currently embedded in the index.
  final int chunkCount;

  /// Per-source-kind breakdown, e.g. `{'doc': 47, 'symbol': 312, 'hook': 8}`.
  final Map<String, int> chunkCountsByKind;

  /// Number of indexed sources whose content fingerprint no longer
  /// matches the on-disk source. Zero means the index is up to date.
  final int staleSourceCount;

  /// Human-readable phase string while a rebuild is in progress
  /// (`'Chunking docs…'`, `'Embedding…'`, etc.). Null when idle.
  final String? inProgressPhase;

  bool get isInProgress => inProgressPhase != null;
  bool get neverBuilt => lastBuiltAt == null && !isInProgress;
  bool get isStale => staleSourceCount > 0;

  /// Initial state for a project that has no index file yet.
  static const empty = RagIndexStatus(
    lastBuiltAt: null,
    chunkCount: 0,
    chunkCountsByKind: {},
    staleSourceCount: 0,
    inProgressPhase: null,
  );

  /// Transient state set between "user clicked Open Project" and the
  /// first [RagIndex.statusSnapshot] completing. Renders as a sync
  /// icon + "Checking…" in the RAG card (via the existing
  /// [isInProgress] branch) so the user doesn't see a "Never built"
  /// flash for a project that actually has a built index.
  static const checking = RagIndexStatus(
    lastBuiltAt: null,
    chunkCount: 0,
    chunkCountsByKind: {},
    staleSourceCount: 0,
    inProgressPhase: 'Checking…',
  );
}
