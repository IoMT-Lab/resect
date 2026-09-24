import 'rag_index.dart' show RagHit;

/// A cosine-retrieval source of context chunks. Implemented by the
/// per-project [RagIndex] and the shared per-chip corpus index; prompt
/// composers accept this so they don't care where chunks live.
///
/// Deliberately NOT blended into one composite: the project index and
/// the chip corpus answer different questions and are rendered as
/// separate labeled prompt sections. Blending cosine scores across
/// differently-distributed corpora is a correctness trap.
// ignore: one_member_abstracts
abstract class Retriever {
  Future<List<RagHit>> retrieve(
    String queryText, {
    int topK = 10,
    Set<String>? kinds,
    Set<int> exclude = const {},
  });
}
