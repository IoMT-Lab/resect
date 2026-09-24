/// Builds retrieval queries from what a synthesis/auto-tune moment
/// knows: the target or halt symbol, an optional freeform prompt, and
/// the platform description. One builder feeds both the embedding query
/// and the corpus index's FTS prefilter, so the two stay in agreement.
library;

class RetrievalQuery {
  const RetrievalQuery({
    required this.embedText,
    required this.ftsTerms,
    this.part,
  });

  /// Text handed to the embedding model.
  final String embedText;

  /// Lowercased identifier terms for SQL-side FTS prefiltering
  /// (deduped, length ≥ 3, no reserved characters).
  final Set<String> ftsTerms;

  /// Exact part when known — corpus retrieval scopes `part IS NULL OR
  /// part = ?` with it.
  final String? part;
}

class RetrievalQueryBuilder {
  RetrievalQueryBuilder._();

  /// `usart1: UART.STM32_UART @ sysbus 0x40013800` → 'usart1'.
  static final _replRegistration =
      RegExp(r'^(\w+):\s*[A-Za-z]+\.[A-Za-z0-9_]+\s*@', multiLine: true);

  static final _identSplit = RegExp(r'[_\W]+|(?<=[a-z0-9])(?=[A-Z])');

  static RetrievalQuery build({
    String? symbol,
    String? userPrompt,
    String? replContent,
    String? part,
  }) {
    final peripherals = <String>[];
    if (replContent != null) {
      for (final m in _replRegistration.allMatches(replContent)) {
        final name = m.group(1)!.toLowerCase();
        if (name != 'cpu' && name != 'sysbus' && name != 'nvic') {
          peripherals.add(name);
        }
      }
    }

    final embedText = [
      if (userPrompt != null && userPrompt.trim().isNotEmpty) userPrompt.trim(),
      if (symbol != null && symbol.isNotEmpty) symbol,
      if (peripherals.isNotEmpty) 'peripherals: ${peripherals.join(' ')}',
    ].join('\n');

    final terms = <String>{};
    void addTermsOf(String s) {
      for (final t in s.split(_identSplit)) {
        final lower = t.toLowerCase();
        if (lower.length >= 3 && RegExp(r'^[a-z0-9]+$').hasMatch(lower)) {
          terms.add(lower);
        }
      }
    }

    if (symbol != null) addTermsOf(symbol);
    peripherals.forEach(terms.add);
    // Deliberately NOT the freeform prompt — prose words make FTS
    // prefilters too broad; identifiers are the discriminative tokens.

    return RetrievalQuery(
      embedText: embedText.isEmpty ? (symbol ?? '') : embedText,
      ftsTerms: terms,
      part: part,
    );
  }
}
