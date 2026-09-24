/// Embedding blob encoding + cosine similarity, shared by the
/// per-project [RagIndex] and the per-chip corpus index. Pure functions,
/// extracted verbatim from rag_index.dart so both stores agree on the
/// wire format (little-endian float32 blobs).
library;

import 'dart:math' as math;
import 'dart:typed_data';

Uint8List float32ToBlob(Float32List v) =>
    v.buffer.asUint8List(v.offsetInBytes, v.lengthInBytes);

Float32List blobToFloat32(Uint8List bytes) {
  // Embedding rows are always written by [float32ToBlob], which
  // produces a length divisible by 4. SQLite hands us a fresh buffer
  // each select, so we can wrap it without copying.
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(bytes.lengthInBytes ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

/// Sum of squares (NOT the root) — [cosine] takes the root itself.
double sumOfSquares(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  return s == 0 ? 1 : s;
}

double cosine(Float32List a, Float32List b, double aSumOfSquares) {
  var dot = 0.0;
  var bNorm = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    bNorm += b[i] * b[i];
  }
  if (bNorm == 0) return 0;
  return dot / (math.sqrt(aSumOfSquares) * math.sqrt(bNorm));
}
