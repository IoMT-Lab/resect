import 'dart:convert';

/// One recommendation extracted from a (possibly partial) advisor
/// response. Field names mirror the wire schema; anything the model
/// hasn't finished streaming is simply absent from [PartialLlmParse.recs].
class PartialRec {
  const PartialRec({
    required this.kind,
    this.symbol,
    this.scope,
    this.artifactId,
    this.newValue,
    this.rationale,
  });

  final String kind;
  final String? symbol;
  final String? scope;
  final int? artifactId;
  final int? newValue;
  final String? rationale;
}

class PartialLlmParse {
  const PartialLlmParse({this.prose, this.recs = const [], this.complete = false});

  final String? prose;
  final List<PartialRec> recs;

  /// True when the whole buffer decoded as valid JSON (the stream is
  /// finished or the model closed the document).
  final bool complete;

  bool get isEmpty => prose == null && recs.isEmpty;
}

/// Progressively parse the advisor's streamed JSON so the UI can render
/// `prose` and each recommendation AS THE MODEL COMPLETES THEM instead
/// of showing raw JSON.
///
/// Strategy: decode the whole buffer when it's already valid JSON;
/// otherwise extract the closed `"prose"` string and every
/// syntactically complete `{…}` object inside the `"recommendations"`
/// array (brace-depth scan that respects JSON strings/escapes), then
/// decode each candidate object individually — a candidate that fails
/// to decode is skipped, never thrown.
PartialLlmParse parsePartialRecommendationJson(String buffer) {
  final text = buffer.trim();
  if (text.isEmpty) return const PartialLlmParse();

  // Complete document — the cheap, exact path.
  try {
    final doc = jsonDecode(text);
    if (doc is Map<String, dynamic>) {
      return PartialLlmParse(
        prose: doc['prose'] as String?,
        recs: [
          for (final r in (doc['recommendations'] as List? ?? const []))
            if (r is Map<String, dynamic>) _rec(r),
        ],
        complete: true,
      );
    }
  } catch (_) {
    // Partial — fall through to incremental extraction.
  }

  return PartialLlmParse(
    prose: _closedStringField(text, 'prose'),
    recs: [
      for (final obj in _completeObjectsInArray(text, 'recommendations'))
        if (_tryDecode(obj) case final Map<String, dynamic> m) _rec(m),
    ],
  );
}

PartialRec _rec(Map<String, dynamic> m) => PartialRec(
      kind: m['kind'] as String? ?? '?',
      symbol: m['symbol'] as String?,
      scope: m['scope'] as String?,
      artifactId: (m['artifact_id'] as num?)?.toInt() ??
          (m['artifactId'] as num?)?.toInt(),
      newValue: (m['new_value'] as num?)?.toInt() ??
          (m['newValue'] as num?)?.toInt(),
      rationale: m['rationale'] as String?,
    );

Object? _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

/// The value of `"<field>": "…"` when its closing quote has streamed,
/// decoded with JSON escape handling; null while still open or absent.
String? _closedStringField(String text, String field) {
  final start = text.indexOf('"$field"');
  if (start < 0) return null;
  final colon = text.indexOf(':', start + field.length + 2);
  if (colon < 0) return null;
  final open = text.indexOf('"', colon + 1);
  if (open < 0) return null;
  var i = open + 1;
  while (i < text.length) {
    final c = text[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    if (c == '"') {
      final raw = text.substring(open, i + 1);
      return _tryDecode(raw) as String?;
    }
    i++;
  }
  return null; // string still streaming
}

/// Raw source of each brace-balanced `{…}` object inside
/// `"<field>": [ … ` — complete objects only; the trailing half-streamed
/// one (unbalanced braces) is left out.
List<String> _completeObjectsInArray(String text, String field) {
  final start = text.indexOf('"$field"');
  if (start < 0) return const [];
  final bracket = text.indexOf('[', start);
  if (bracket < 0) return const [];

  final out = <String>[];
  var depth = 0;
  var inString = false;
  int? objStart;
  for (var i = bracket + 1; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    switch (c) {
      case '"':
        inString = true;
      case '{':
        if (depth == 0) objStart = i;
        depth++;
      case '}':
        depth--;
        if (depth == 0 && objStart != null) {
          out.add(text.substring(objStart, i + 1));
          objStart = null;
        }
      case ']':
        if (depth == 0) return out; // array closed
    }
  }
  return out;
}
