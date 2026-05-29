import 'comms_classifier.dart' show tokenize;

/// Returns a guess at a useful Renode hook `scope` string for [symbolName],
/// or an empty string when no good guess is available.
///
/// Heuristic: tokenize the symbol name (same rules as the comms classifier),
/// drop a single leading framework prefix when present (`LL`, `HAL`), strip
/// common action verbs anywhere in the token list, and return the last
/// remaining token. The intent is the most-specific identifier, not the
/// outermost subsystem — so `LL_RCC_HSE_Enable` suggests `HSE`, not `RCC`.
///
/// Examples:
/// - `LL_RCC_HSE_Enable`     → `HSE`
/// - `HAL_GPIO_Init`         → `GPIO`
/// - `LL_I2C_Enable`         → `I2C`
/// - `HAL_RCC_OscConfig`     → `Osc`
/// - `LL_RCC_GetSystemClock` → `Clock`
/// - `foo_bar`               → `bar`
/// - `Foo`                   → `Foo`
///
/// Suggestions are suggestions — the UI prefills a text field with the
/// result and the user can replace it with anything.
String suggestScopeFromSymbol(String symbolName) {
  final tokens = tokenize(symbolName);
  if (tokens.isEmpty) return '';

  if (tokens.length > 1 &&
      _frameworkPrefixes.contains(tokens.first.toUpperCase())) {
    tokens.removeAt(0);
  }

  tokens.removeWhere((t) => _actionWords.contains(t.toLowerCase()));

  return tokens.isEmpty ? '' : tokens.last;
}

const _frameworkPrefixes = {'LL', 'HAL'};

const _actionWords = {
  'init', 'deinit', 'enable', 'disable', 'reset',
  'start', 'stop', 'set', 'get', 'configure', 'config',
  'toggle', 'open', 'close', 'read', 'write', 'send',
  'receive', 'recv', 'put',
};
