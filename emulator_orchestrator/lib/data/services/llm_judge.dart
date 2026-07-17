/// LLM-as-judge layer (Layer 3 of the quality metric per plan
/// §Q2-answer). Runs only AFTER the gate (Layer 1) passes; produces
/// a 0.0-1.0 score by asking a model to pairwise-rank the candidate
/// hook against a baseline.
///
/// Two calls per evaluation, with the candidate and baseline labels
/// swapped on the second call, to control position bias (Zheng et
/// al. NeurIPS 2023, MT-Bench). The two scores are averaged.
///
/// **Catalog-materialised hooks skip this layer**: when the
/// classifier fires, the hook is deterministically a catalog
/// template — judging it against itself is circular, and the
/// catalog template is correct by construction. The scorer treats
/// classifier-fired = Layer 3 score 1.0 automatically.
///
/// LLM-path hooks (Rules 8/9 fall-through) DO use this layer.
/// Their baseline is the "no-op substitute" (`import
/// set_return_value; setReturnValue(cpu, 0)`) — the
/// minimum-effort hook a substitute could ever be. The judge
/// chooses whether the LLM's richer output beats the bare no-op
/// for this function's purpose.
library;

import 'dart:async';
import 'dart:convert';

import 'llm_client.dart';
import 'llm_profiles.dart';

/// Outcome of one judge evaluation. The score is the candidate's
/// quality on a 0-1 scale; lower means the baseline was preferred,
/// higher means the candidate was preferred.
class LlmJudgeResult {
  const LlmJudgeResult({
    required this.score,
    required this.justification,
    required this.modelUsed,
    required this.callA,
    required this.callB,
  });

  /// 0.0-1.0. 0.0 = baseline wins both orderings unambiguously.
  /// 1.0 = candidate wins both orderings unambiguously. 0.5 = the
  /// model judged them equivalent, OR the two orderings disagreed.
  final double score;

  /// Concatenated one-line rationales from the two orderings;
  /// surfaced in the dialog's quality breakdown.
  final String justification;

  /// Which model produced the judgement. Same as the generator's
  /// model when no separate judge model is configured. Logged in
  /// the report so a same-family judging arrangement is visible.
  final String modelUsed;

  /// Raw text response from the first ordering (candidate=A).
  /// Surfaced for debugging; not used in scoring.
  final String callA;

  /// Raw text response from the second ordering (candidate=B).
  final String callB;
}

/// Pairwise judge. Stateless beyond the [LlmClient] it wraps.
class LlmJudge {
  LlmJudge({required this.client, this.judgeModelOverride});

  final LlmClient client;

  /// Optional override for the judge's model tag. When null, the
  /// judge uses whatever model the [client] is configured for (same
  /// model as the generator — logged in the result so a same-family
  /// judging arrangement is visible).
  final String? judgeModelOverride;

  /// Run the pairwise evaluation. Two LLM calls, ~30-60 s each on
  /// CPU. Caller should run this in the background; the dialog
  /// can update the score strip when [evaluate] resolves.
  Future<LlmJudgeResult> evaluate({
    required String candidateHook,
    required String baselineHook,
    required String functionName,
    required String decompilation,
  }) async {
    final callA = await _askJudge(
      functionName: functionName,
      decompilation: decompilation,
      hookA: candidateHook,
      hookB: baselineHook,
    );
    final callB = await _askJudge(
      functionName: functionName,
      decompilation: decompilation,
      hookA: baselineHook,
      hookB: candidateHook,
    );

    // Map each call's verdict to a candidate-quality contribution
    // in [0, 1]. Candidate was labelled A in call 1; B in call 2.
    final qA = _qualityFromVerdict(callA, candidateLabel: 'A');
    final qB = _qualityFromVerdict(callB, candidateLabel: 'B');
    final avg = (qA + qB) / 2.0;

    final justification = [
      'Order 1 (candidate=A): ${callA.reason}',
      'Order 2 (candidate=B): ${callB.reason}',
    ].join('  |  ');

    return LlmJudgeResult(
      score: avg,
      justification: justification,
      modelUsed: judgeModelOverride ?? client.model,
      callA: callA.raw,
      callB: callB.raw,
    );
  }

  Future<_Verdict> _askJudge({
    required String functionName,
    required String decompilation,
    required String hookA,
    required String hookB,
  }) async {
    final prompt = _buildRubricPrompt(
      functionName: functionName,
      decompilation: decompilation,
      hookA: hookA,
      hookB: hookB,
    );
    final buf = StringBuffer();
    // Judge params come from the shared profile (think-off / temp-0 /
    // 256 tokens — a short structured-output task; reasoning would
    // eat the budget before any response bytes appear). The verdict
    // schema makes the output constrained-decoded, so `_parseVerdict`
    // below is now the safety net rather than the load-bearing path.
    const p = LlmProfiles.judge;
    await for (final chunk in client.generate(
      prompt,
      system: _kJudgeSystemPrompt,
      think: p.think,
      temperature: p.temperature,
      topP: p.topP,
      topK: p.topK,
      numCtx: p.numCtx,
      numPredict: p.numPredict,
      format: _kVerdictSchema,
    )) {
      buf.write(chunk);
    }
    return _parseVerdict(buf.toString());
  }
}

/// Internal: judge verdict shape, parsed from the model's JSON.
class _Verdict {
  const _Verdict({
    required this.winner, // 'A' | 'B' | 'tie' | 'unknown'
    required this.confidence,
    required this.reason,
    required this.raw,
  });
  final String winner;
  final double confidence;
  final String reason;
  final String raw;
}

double _qualityFromVerdict(_Verdict v, {required String candidateLabel}) {
  if (v.winner == 'tie' || v.winner == 'unknown') return 0.5;
  final candidateWon = v.winner == candidateLabel;
  return candidateWon ? 0.5 + 0.5 * v.confidence : 0.5 - 0.5 * v.confidence;
}

/// Ollama constrained-decoding schema for the verdict. Mirrors the
/// shape `_parseVerdict` expects; with this in effect the response
/// channel can only emit a conforming object, so malformed-JSON
/// verdicts (previously → winner 'unknown' → score 0.5) become
/// unreachable. `winner` matches the prompt's "A" | "B" | "tie".
const _kVerdictSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'winner': {
      'type': 'string',
      'enum': ['A', 'B', 'tie'],
    },
    'confidence': {'type': 'number'},
    'reason': {'type': 'string'},
  },
  'required': ['winner', 'confidence', 'reason'],
};

const _kJudgeSystemPrompt = '''
You are evaluating substitute hooks for emulated firmware functions.

Definition of "good substitute": the hook lets the firmware's caller
continue without crashing the emulator. It MUST NOT replicate
peripheral I/O the original function performs — peripheral writes
generate unhandled memory accesses in emulation and break the
firmware. It MUST return values the caller can act on safely (e.g.
HAL_OK for status, monotonically-advancing for tick counters,
plausible-default for clock-frequency queries).

You will see the function name, its decompiled body, and two
candidate hooks A and B. Pick the better substitute. Reply with
ONLY a JSON object on a single line:

{"winner": "A" | "B" | "tie", "confidence": 0.0-1.0, "reason": "one sentence"}

No preamble, no markdown fences, no explanation outside the
"reason" field. Confidence 1.0 = unambiguous; 0.0 = coin flip.
''';

String _buildRubricPrompt({
  required String functionName,
  required String decompilation,
  required String hookA,
  required String hookB,
}) =>
    '''
## Function

$functionName

## Decompiled body (the original function's behaviour)

```c
${decompilation.trim()}
```

## Hook A

```python
${hookA.trim()}
```

## Hook B

```python
${hookB.trim()}
```

## Verdict
''';

/// Parse the model's reply. Tolerant of leading/trailing chatter;
/// extracts the first JSON object that has the expected fields.
_Verdict _parseVerdict(String raw) {
  final trimmed = raw.trim();
  final braceIdx = trimmed.indexOf('{');
  if (braceIdx < 0) {
    return _Verdict(
      winner: 'unknown',
      confidence: 0.0,
      reason: 'no JSON object found in response',
      raw: raw,
    );
  }
  // Scan to the matching '}' (single-level brace count; the JSON
  // schema we ask for is flat).
  var depth = 0;
  var end = -1;
  for (var i = braceIdx; i < trimmed.length; i++) {
    final c = trimmed[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) {
        end = i + 1;
        break;
      }
    }
  }
  if (end < 0) {
    return _Verdict(
      winner: 'unknown',
      confidence: 0.0,
      reason: 'unbalanced JSON in response',
      raw: raw,
    );
  }
  final blob = trimmed.substring(braceIdx, end);
  try {
    final obj = jsonDecode(blob) as Map<String, dynamic>;
    final winnerRaw = (obj['winner'] as String?)?.trim().toUpperCase();
    final winner = (winnerRaw == 'A' || winnerRaw == 'B' || winnerRaw == 'TIE')
        ? (winnerRaw == 'TIE' ? 'tie' : winnerRaw!)
        : 'unknown';
    final confidence = (obj['confidence'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0;
    final reason = (obj['reason'] as String?) ?? '<no reason>';
    return _Verdict(
      winner: winner,
      confidence: confidence,
      reason: reason,
      raw: raw,
    );
  } catch (e) {
    return _Verdict(
      winner: 'unknown',
      confidence: 0.0,
      reason: 'JSON parse error: $e',
      raw: raw,
    );
  }
}
