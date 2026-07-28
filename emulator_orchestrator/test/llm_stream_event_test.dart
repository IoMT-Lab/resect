import 'dart:async';
import 'dart:convert';

import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:test/test.dart';

/// Run [lines] through [parseGenerateNdjson] and collect the events.
/// Each entry of [lines] is one NDJSON object encoded as a string,
/// matching what `HttpClientResponse.transform(LineSplitter())` would
/// yield in the production path.
Future<List<LlmStreamEvent>> parse(List<String> lines) =>
    parseGenerateNdjson(Stream<String>.fromIterable(lines)).toList();

void main() {
  group('parseGenerateNdjson', () {
    test('response-only line yields one LlmResponseChunk', () async {
      final events = await parse([
        jsonEncode({'response': 'hello', 'done': false}),
      ]);
      expect(events, hasLength(1));
      expect(events.single, isA<LlmResponseChunk>());
      expect((events.single as LlmResponseChunk).text, 'hello');
    });

    test('thinking-only line yields one LlmThinkingChunk', () async {
      final events = await parse([
        jsonEncode({'thinking': 'reasoning…', 'done': false}),
      ]);
      expect(events, hasLength(1));
      expect(events.single, isA<LlmThinkingChunk>());
      expect((events.single as LlmThinkingChunk).text, 'reasoning…');
    });

    test('both fields present yields thinking first then response',
        () async {
      final events = await parse([
        jsonEncode({
          'thinking': 'why',
          'response': 'because',
          'done': false,
        }),
      ]);
      expect(events, hasLength(2));
      expect(events[0], isA<LlmThinkingChunk>());
      expect((events[0] as LlmThinkingChunk).text, 'why');
      expect(events[1], isA<LlmResponseChunk>());
      expect((events[1] as LlmResponseChunk).text, 'because');
    });

    test('done: true terminates the stream mid-line-sequence', () async {
      final events = await parse([
        jsonEncode({'response': 'first', 'done': false}),
        jsonEncode({
          'response': 'last',
          'done': true,
          'done_reason': 'stop',
          'eval_count': 2,
        }),
        // The line below should never be consumed — `done: true`
        // breaks the parser loop.
        jsonEncode({'response': 'after-done', 'done': false}),
      ]);
      expect(events, hasLength(3));
      expect((events[0] as LlmResponseChunk).text, 'first');
      expect((events[1] as LlmResponseChunk).text, 'last');
      expect(events[2], isA<LlmStreamDone>());
    });

    test('empty lines are skipped', () async {
      final events = await parse([
        '',
        jsonEncode({'response': 'a', 'done': false}),
        '',
        jsonEncode({
          'response': 'b',
          'done': true,
          'done_reason': 'stop',
          'eval_count': 2,
        }),
      ]);
      expect(events, hasLength(3));
      expect((events[0] as LlmResponseChunk).text, 'a');
      expect((events[1] as LlmResponseChunk).text, 'b');
      expect(events[2], isA<LlmStreamDone>());
    });

    test('empty-string thinking and response fields are filtered',
        () async {
      final events = await parse([
        jsonEncode({
          'thinking': '',
          'response': '',
          'done': false,
        }),
        jsonEncode({
          'response': 'real',
          'done': true,
          'done_reason': 'stop',
          'eval_count': 1,
        }),
      ]);
      // The empty-strings line produces zero events; the next line
      // yields one response + one terminal done.
      expect(events, hasLength(2));
      expect((events[0] as LlmResponseChunk).text, 'real');
      expect(events[1], isA<LlmStreamDone>());
    });

    test('error field throws LlmClientException', () async {
      final lines = Stream<String>.fromIterable([
        jsonEncode({'error': 'context length exceeded'}),
      ]);
      expect(
        () => parseGenerateNdjson(lines).toList(),
        throwsA(isA<LlmClientException>()),
      );
    });

    test('error mid-stream throws and stops further consumption',
        () async {
      final lines = Stream<String>.fromIterable([
        jsonEncode({'response': 'partial', 'done': false}),
        jsonEncode({'error': 'oom'}),
        jsonEncode({'response': 'should-not-reach', 'done': true}),
      ]);
      final stream = parseGenerateNdjson(lines);
      final collected = <LlmStreamEvent>[];
      try {
        await for (final ev in stream) {
          collected.add(ev);
        }
        fail('expected LlmClientException');
      } on LlmClientException {
        // Partial events delivered before the error event must still
        // reach the consumer.
        expect(collected, hasLength(1));
        expect((collected.single as LlmResponseChunk).text, 'partial');
      }
    });

    test(
        'long realistic sequence: alternating thinking + response, '
        'then a final done line', () async {
      final events = await parse([
        jsonEncode({'thinking': 'analyzing the call graph…'}),
        jsonEncode({'thinking': ' considering ratelimits…'}),
        jsonEncode({'response': '{"prose":'}),
        jsonEncode({'response': '"set forced override"}'}),
        jsonEncode({
          'response': '',
          'done': true,
          'done_reason': 'stop',
          'eval_count': 7,
        }),
      ]);
      expect(events, hasLength(5));
      expect(events.whereType<LlmThinkingChunk>().length, 2);
      expect(events.whereType<LlmResponseChunk>().length, 2);
      expect(events.last, isA<LlmStreamDone>());
      final fullResponse = events
          .whereType<LlmResponseChunk>()
          .map((e) => e.text)
          .join();
      expect(fullResponse, '{"prose":"set forced override"}');
    });

    test('LlmStreamDone carries done_reason + eval_count + thinking chunk count',
        () async {
      final events = await parse([
        jsonEncode({'thinking': 'one'}),
        jsonEncode({'thinking': 'two'}),
        jsonEncode({'thinking': 'three'}),
        jsonEncode({'response': 'hi'}),
        jsonEncode({
          'done': true,
          'done_reason': 'stop',
          'eval_count': 1,
        }),
      ]);
      final done = events.last as LlmStreamDone;
      expect(done.doneReason, 'stop');
      expect(done.responseTokens, 1);
      expect(done.thinkingChunks, 3);
    });

    test(
        'LlmStreamDone with done_reason=length and zero response tokens '
        '(the budget-exhaustion case the auto-tune flow needs to detect)',
        () async {
      // Simulate the exact failure mode from the user's screenshot:
      // many thinking chunks, zero response chunks, num_predict
      // budget consumed, Ollama signals done_reason: length.
      final lines = <String>[];
      for (var i = 0; i < 25; i++) {
        lines.add(jsonEncode({'thinking': 'token-$i'}));
      }
      lines.add(jsonEncode({
        'done': true,
        'done_reason': 'length',
        'eval_count': 0,
      }));
      final events = await parse(lines);
      expect(events.whereType<LlmResponseChunk>(), isEmpty);
      expect(events.whereType<LlmThinkingChunk>().length, 25);
      final done = events.last as LlmStreamDone;
      expect(done.doneReason, 'length');
      expect(done.responseTokens, 0);
      expect(done.thinkingChunks, 25);
    });

    test('LlmStreamDone uses safe defaults when done_reason / eval_count absent',
        () async {
      // Older Ollama builds (or non-standard endpoints) may omit
      // these fields. Parser must not crash.
      final events = await parse([
        jsonEncode({'response': 'x', 'done': true}),
      ]);
      expect(events, hasLength(2));
      final done = events.last as LlmStreamDone;
      expect(done.doneReason, 'unknown');
      expect(done.responseTokens, 0);
      expect(done.thinkingChunks, 0);
    });
  });
}
