import 'package:emulator_ui/presentation/screens/synthesize/widgets/partial_llm_json.dart';
import 'package:flutter_test/flutter_test.dart';

/// Progressive parsing of the advisor's streamed JSON: closed fields
/// render as they complete; half-streamed content never throws and
/// never leaks.
void main() {
  test('complete JSON parses prose and every recommendation', () {
    final p = parsePartialRecommendationJson('''
{
  "prose": "Force the leaf.",
  "recommendations": [
    {"kind": "set_forced_override", "symbol": "uart_rx_getc",
     "artifact_id": 2, "rationale": "polling loop"},
    {"kind": "adjust_iteration_cap", "new_value": 20,
     "rationale": "more room"}
  ]
}''');
    expect(p.complete, isTrue);
    expect(p.prose, 'Force the leaf.');
    expect(p.recs, hasLength(2));
    expect(p.recs[0].kind, 'set_forced_override');
    expect(p.recs[0].symbol, 'uart_rx_getc');
    expect(p.recs[0].artifactId, 2);
    expect(p.recs[1].newValue, 20);
  });

  test('prose-only prefix parses once its closing quote streams', () {
    final p = parsePartialRecommendationJson(
        '{\n  "prose": "The firmware appears stuck polling the UART", '
        '\n  "recommendations": [');
    expect(p.complete, isFalse);
    expect(p.prose, 'The firmware appears stuck polling the UART');
    expect(p.recs, isEmpty);
  });

  test('still-open prose string is withheld', () {
    final p = parsePartialRecommendationJson(
        '{ "prose": "The firmware appears stuck poll');
    expect(p.prose, isNull);
    expect(p.isEmpty, isTrue);
  });

  test('one complete + one half-streamed recommendation → only the '
      'complete one', () {
    final p = parsePartialRecommendationJson('''
{ "prose": "p",
  "recommendations": [
    {"kind": "set_forced_override", "symbol": "A", "artifact_id": 7},
    {"kind": "set_preference", "symbol": "B", "artifa''');
    expect(p.complete, isFalse);
    expect(p.recs, hasLength(1));
    expect(p.recs.single.symbol, 'A');
    expect(p.recs.single.artifactId, 7);
  });

  test('escaped quotes and braces inside strings are handled', () {
    final p = parsePartialRecommendationJson(r'''
{ "prose": "she said \"go\" {now}",
  "recommendations": [
    {"kind": "set_forced_override", "symbol": "X",
     "rationale": "loop {while \"busy\"}"}
  ],''');
    expect(p.prose, 'she said "go" {now}');
    expect(p.recs.single.rationale, 'loop {while "busy"}');
  });

  test('garbage parses to nothing without throwing', () {
    expect(parsePartialRecommendationJson('not json at all').isEmpty, isTrue);
    expect(parsePartialRecommendationJson('').isEmpty, isTrue);
    expect(parsePartialRecommendationJson('{ "recommendations": [ {broken')
        .isEmpty, isTrue);
  });
}
