import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:emulator_orchestrator/services/rag/retriever.dart';
import 'package:test/test.dart';

RagHit hit(int id, String kind, String text) => RagHit(
    id: id, sourceKind: kind, sourceId: '$kind$id', text: text, score: 1.0);

class _FakeRetriever implements Retriever {
  _FakeRetriever(this.byKind);
  final Map<String, List<RagHit>> byKind;

  @override
  Future<List<RagHit>> retrieve(String queryText,
      {int topK = 10, Set<String>? kinds, Set<int> exclude = const {}}) async {
    final out = <RagHit>[];
    for (final k in kinds ?? const <String>{}) {
      out.addAll(byKind[k] ?? const []);
    }
    return out.where((h) => !exclude.contains(h.id)).take(topK).toList();
  }
}

/// A RagIndex whose retrieve() is faked so composePrompt runs without a
/// live sqlite index.
class _ProjectShim implements RagIndex {
  _ProjectShim(this.byKind);
  final Map<String, List<RagHit>> byKind;

  @override
  Future<List<RagHit>> retrieve(String queryText,
      {int topK = 10, Set<String>? kinds, Set<int> exclude = const {}}) async {
    final out = <RagHit>[];
    for (final k in kinds ?? const <String>{}) {
      out.addAll(byKind[k] ?? const []);
    }
    return out.where((h) => !exclude.contains(h.id)).take(topK).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LlmClient fakeClient() => LlmClient(host: 'localhost:0', model: 'x');

void main() {
  test('corpus hits render as ## Chip SDK context, additive to project',
      () async {
    final project = _ProjectShim({
      'hook': [hit(1, 'hook', 'example hook body')],
      'symbol': [hit(2, 'symbol', 'project symbol chunk')],
    });
    final corpus = _FakeRetriever({
      'svd_register': [hit(9, 'svd_register', 'USART1 @ 0x40013800 CR1 UE TE')],
    });

    final gen = LlmHookGenerator(
      index: project,
      client: fakeClient(),
      corpusRetriever: corpus,
      corpusPart: 'STM32WB05',
    );
    final prompt = await gen.composePrompt(
        userPrompt: 'substitute', targetSymbol: 'HAL_UART_Transmit');

    expect(prompt, contains('## Chip SDK context (STM32WB05)'));
    expect(prompt, contains('Registers (SVD)'));
    expect(prompt, contains('USART1'));
    expect(prompt, contains('## Project context'));
    expect(prompt, contains('project symbol chunk'),
        reason: 'corpus is additive; project context untouched');
  });

  test('no corpus retriever → no Chip SDK context section', () async {
    final project = _ProjectShim({
      'symbol': [hit(2, 'symbol', 'project symbol chunk')],
    });
    final gen = LlmHookGenerator(index: project, client: fakeClient());
    final prompt = await gen.composePrompt(
        userPrompt: 'substitute', targetSymbol: 'HAL_UART_Transmit');
    expect(prompt, isNot(contains('Chip SDK context')));
    expect(prompt, contains('## Project context'));
  });
}
